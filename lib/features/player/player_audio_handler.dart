import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:bass_player/bass_player.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/services/app_logger.dart';
import '../../core/ui/cover_image_source.dart';
import 'media_item_copy.dart';

typedef PlayerTransportCallback = Future<void> Function();
typedef PlayerQueueItemCallback = Future<void> Function(int index);
typedef PlayerRepeatModeCallback =
    Future<void> Function(AudioServiceRepeatMode mode);
typedef PlayerShuffleModeCallback =
    Future<void> Function(AudioServiceShuffleMode mode);

const playerAudioServiceConfig = AudioServiceConfig(
  androidNotificationChannelId: 'com.cyshine.music.channel.audio_playback',
  androidNotificationChannelName: '音乐播放',
  androidNotificationChannelDescription: '显示正在播放的歌曲和媒体控制',
  androidNotificationIcon: 'drawable/ic_stat_music_note',
  androidShowNotificationBadge: false,
  androidNotificationOngoing: false,
  // Keep the MediaSession and notification alive while a track is paused or
  // replaced. Restarting a foreground service from the lock screen is not
  // reliable across Android vendors and can leave stale system metadata.
  androidStopForegroundOnPause: false,
  notificationColor: Color(0xFF006A60),
  artDownscaleWidth: 512,
  artDownscaleHeight: 512,
);

/// Upper bound for a single [PlayerAudioHandler.load] attempt.
const playerLoadTimeout = Duration(seconds: 40);

class PlayerLoadTimeoutException implements Exception {
  const PlayerLoadTimeoutException(this.timeout);

  final Duration timeout;

  @override
  String toString() => '加载超时（${timeout.inSeconds} 秒），文件可能过大或音源响应过慢';
}

AudioSessionConfiguration playerAudioSessionConfiguration({
  required bool allowMixWithOthers,
}) {
  if (!allowMixWithOthers) {
    return const AudioSessionConfiguration.music();
  }
  return const AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playback,
    avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
    avAudioSessionMode: AVAudioSessionMode.defaultMode,
    androidAudioAttributes: AndroidAudioAttributes(
      contentType: AndroidAudioContentType.music,
      usage: AndroidAudioUsage.media,
    ),
    androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
  );
}

bool shouldActivatePlayerAudioSession({
  required bool allowMixWithOthers,
  required bool isAndroid,
}) => !allowMixWithOthers || !isAndroid;

Future<PlayerAudioHandler> initializePlayerAudioHandler({
  bool allowMixWithOthers = false,
}) async {
  final handler = await AudioService.init<PlayerAudioHandler>(
    builder: () => PlayerAudioHandler(allowMixWithOthers: allowMixWithOthers),
    config: playerAudioServiceConfig,
  );

  await handler.setAllowMixWithOthers(allowMixWithOthers);
  return handler;
}

class PlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  PlayerAudioHandler({bool allowMixWithOthers = false, BassPlayer? player})
    : _player = player ?? BassPlayer(),
      _allowMixWithOthers = allowMixWithOthers {
    _playbackSubscription = _player.playbackEventStream.listen(_broadcastState);
    _durationSubscription = _player.durationStream.listen(_updateDuration);
    _errorSubscription = _player.errorStream.listen((error) {
      _broadcastError(error, StackTrace.current);
    });
    _broadcastState(_player.snapshot);
  }

  final BassPlayer _player;
  bool _allowMixWithOthers;
  bool _audioSessionConfigured = false;
  bool _engineInitialized = false;
  BassEqualizerConfiguration? _pendingEqualizer;
  StreamSubscription<BassPlaybackSnapshot>? _playbackSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<BassPlayerException>? _errorSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  bool _resumeAfterInterruption = false;
  bool _ducked = false;
  int _pauseGeneration = 0;

  Object? _callbackOwner;
  PlayerTransportCallback? _onPrevious;
  PlayerTransportCallback? _onNext;
  PlayerQueueItemCallback? _onQueueItem;
  PlayerRepeatModeCallback? _onRepeatMode;
  PlayerShuffleModeCallback? _onShuffleMode;
  int? _queueIndex;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.all;
  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  MediaItem? _currentMediaItem;
  MediaItem? _mediaItemBeforeTransition;
  int? _queueIndexBeforeTransition;
  bool _trackTransitionActive = false;

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<BassPlaybackSnapshot> get playerStateStream =>
      _player.playbackEventStream;
  Stream<BassPlayerException> get errorStream => _player.errorStream;
  MediaItem? get currentMediaItem => _currentMediaItem;

  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  BassProcessingState get processingState => _player.processingState;

  Future<void> initializeEngine() async {
    final info = await _player.initialize();
    _engineInitialized = true;
    final pendingEqualizer = _pendingEqualizer;
    _pendingEqualizer = null;
    if (pendingEqualizer != null) {
      await _player.setEqualizer(pendingEqualizer);
    }
    await AppLogger.write(
      'player-engine',
      'BASS ${info.version}; BASS_FX ${info.fxVersion}; '
          'plugins=${info.plugins.entries.map((entry) => '${entry.key}:${entry.value}').join(',')}',
    );
  }

  Future<void> setAllowMixWithOthers(bool value) async {
    unawaited(
      AppLogger.write('audio-session', 'configure allowMixWithOthers=$value'),
    );
    _allowMixWithOthers = value;
    final session = await AudioSession.instance;
    _bindAudioSessionEvents(session);
    await session.configure(
      playerAudioSessionConfiguration(allowMixWithOthers: value),
    );
    _audioSessionConfigured = true;

    if (Platform.isAndroid && value) {
      // Release focus acquired under the normal mode so another app can
      // resume immediately while this player keeps rendering audio.
      await session.setActive(false);
    } else if (_player.playing) {
      await session.setActive(true);
    }
  }

  void _bindAudioSessionEvents(AudioSession session) {
    _interruptionSubscription ??= session.interruptionEventStream.listen(
      (event) => unawaited(handleAudioInterruption(event)),
    );
    _becomingNoisySubscription ??= session.becomingNoisyEventStream.listen(
      (_) => unawaited(_pausePlayer(reason: 'becoming_noisy')),
    );
  }

  @visibleForTesting
  Future<void> handleAudioInterruption(AudioInterruptionEvent event) async {
    unawaited(
      AppLogger.write(
        'audio-session',
        'interruption begin=${event.begin} type=${event.type.name} '
            'playing=${_player.playing} allowMixWithOthers=$_allowMixWithOthers '
            'resumeAfterInterruption=$_resumeAfterInterruption',
      ),
    );
    if (event.type == AudioInterruptionType.duck) {
      _ducked = event.begin;
      await _player.setVolume(event.begin ? 0.2 : 1);
      return;
    }
    if (event.begin) {
      _resumeAfterInterruption = _player.playing;
      if (_resumeAfterInterruption) {
        await _pausePlayer(
          preserveInterruptionResume: true,
          reason: 'audio_interruption_${event.type.name}',
        );
      }
      return;
    }
    if (!_resumeAfterInterruption) return;
    final pauseGeneration = _pauseGeneration;
    _resumeAfterInterruption = false;
    if (_ducked) {
      _ducked = false;
      await _player.setVolume(1);
    }
    if (pauseGeneration != _pauseGeneration) return;
    await play();
  }

  void bindTransportCallbacks({
    required Object owner,
    required PlayerTransportCallback onPrevious,
    required PlayerTransportCallback onNext,
    required PlayerQueueItemCallback onQueueItem,
    required PlayerRepeatModeCallback onRepeatMode,
    required PlayerShuffleModeCallback onShuffleMode,
  }) {
    _callbackOwner = owner;
    _onPrevious = onPrevious;
    _onNext = onNext;
    _onQueueItem = onQueueItem;
    _onRepeatMode = onRepeatMode;
    _onShuffleMode = onShuffleMode;
    _broadcastState(_player.snapshot);
  }

  void unbindTransportCallbacks(Object owner) {
    if (!identical(_callbackOwner, owner)) return;
    _callbackOwner = null;
    _onPrevious = null;
    _onNext = null;
    _onQueueItem = null;
    _onRepeatMode = null;
    _onShuffleMode = null;
  }

  Future<void> beginTrackTransition({
    required MediaItem item,
    int? queueIndex,
  }) async {
    if (!_trackTransitionActive) {
      _mediaItemBeforeTransition = _currentMediaItem;
      _queueIndexBeforeTransition = _queueIndex;
    }
    _trackTransitionActive = true;
    _queueIndex = queueIndex;
    _currentMediaItem = item;
    mediaItem.add(item);
    _broadcastState(_player.snapshot);
    if (_player.playing) {
      _logTransport('pause', reason: 'track_transition');
      await _player.pause();
    }
  }

  void failTrackTransition(Object error) {
    if (!_trackTransitionActive) return;
    final previousItem = _mediaItemBeforeTransition;
    _queueIndex = _queueIndexBeforeTransition;
    if (previousItem != null) {
      _currentMediaItem = previousItem;
      mediaItem.add(previousItem);
    }
    _trackTransitionActive = false;
    _clearTransitionSnapshot();
    final restoredState = _transformEvent(_player.snapshot);
    playbackState.add(
      restoredState.copyWith(
        processingState:
            restoredState.processingState == AudioProcessingState.idle
            ? AudioProcessingState.error
            : restoredState.processingState,
        playing: false,
        errorCode: 1,
        errorMessage: error.toString(),
      ),
    );
  }

  Future<Duration?> load({
    required MediaItem item,
    required Uri sourceUri,
    int? queueIndex,
  }) async {
    _queueIndex = queueIndex;
    _currentMediaItem = item;
    mediaItem.add(item);
    final resolvedDuration = await _loadSourceBounded(
      sourceUri,
      formatHint: item.extras?['quality']?.toString(),
    );
    _trackTransitionActive = false;
    _clearTransitionSnapshot();
    _updateDuration(resolvedDuration);
    _broadcastState(_player.snapshot);
    return resolvedDuration;
  }

  Future<Duration?> _loadSourceBounded(
    Uri sourceUri, {
    String? formatHint,
  }) async {
    if (!_engineInitialized) await initializeEngine();
    final stopwatch = Stopwatch()..start();
    unawaited(
      AppLogger.write(
        'player-load',
        'START scheme=${sourceUri.scheme} host=${sourceUri.host} '
            'format=${formatHint ?? 'unknown'}',
      ),
    );
    final loading = _player.load(sourceUri, formatHint: formatHint);
    try {
      final resolvedDuration = await loading.timeout(playerLoadTimeout);
      stopwatch.stop();
      unawaited(
        AppLogger.write(
          'player-load',
          'OK scheme=${sourceUri.scheme} host=${sourceUri.host} '
              'format=${formatHint ?? 'unknown'} '
              'elapsed=${stopwatch.elapsedMilliseconds}ms '
              'duration=${resolvedDuration?.inMilliseconds ?? -1}ms',
        ),
      );
      return resolvedDuration;
    } on TimeoutException {
      stopwatch.stop();
      unawaited(loading.then((_) {}, onError: (Object _) {}));
      try {
        await _player.stop();
      } catch (_) {
        // Best effort: the load already failed, keep the original reason.
      }
      await AppLogger.write(
        'player-load',
        'TIMEOUT scheme=${sourceUri.scheme} host=${sourceUri.host} '
            'format=${formatHint ?? 'unknown'} '
            'after=${stopwatch.elapsedMilliseconds}ms',
      );
      throw const PlayerLoadTimeoutException(playerLoadTimeout);
    } catch (error) {
      stopwatch.stop();
      await AppLogger.write(
        'player-load',
        'FAIL scheme=${sourceUri.scheme} host=${sourceUri.host} '
            'format=${formatHint ?? 'unknown'} '
            'elapsed=${stopwatch.elapsedMilliseconds}ms: $error',
      );
      rethrow;
    }
  }

  void updateMediaMetadata(MediaItem item) {
    final resolvedDuration = item.duration ?? _player.duration;
    _currentMediaItem = resolvedDuration == null
        ? item
        : preserveMediaItemArtHeaders(
            item,
            item.copyWith(duration: resolvedDuration),
          );
    mediaItem.add(_currentMediaItem);
  }

  void publishQueue(List<MediaItem> items, {int? currentIndex}) {
    _queueIndex = currentIndex;
    queue.add(List<MediaItem>.unmodifiable(items));
    _broadcastState(_player.snapshot);
  }

  void updatePlaybackModes({
    required AudioServiceRepeatMode repeatMode,
    required AudioServiceShuffleMode shuffleMode,
  }) {
    _repeatMode = repeatMode;
    _shuffleMode = shuffleMode;
    _broadcastState(_player.snapshot);
  }

  /// 把封面落成**本地文件**并返回其 [Uri]。
  ///
  /// ★ 为什么必须是本地文件：iOS 的锁屏 / 控制中心卡片由
  /// `MPNowPlayingInfoCenter` 驱动，而 `audio_service` 的 darwin 实现
  /// （`AudioServicePlugin.m` 的 `setMediaItem`）**只**从
  /// `extras['artCacheFile']` 读本地路径来构造 `MPMediaItemArtwork`。
  /// 传一个 http(s) 的 `artUri` 而没有本地文件时，`artwork` 直接是 nil，
  /// 锁屏卡片就没有缩略图 —— 而且整个过程**不报任何错**。
  ///
  /// [bytes] 为内嵌封面（本地音乐）；为 null 时回落到 [fallbackUrl] 下载。
  /// 返回 null 表示拿不到封面，调用方应让 UI 用占位图。
  Future<Uri?> cacheArtwork(Uint8List? bytes, {String? fallbackUrl}) async {
    Uint8List? data = bytes;
    if (data == null || data.isEmpty) {
      data = await _downloadArtwork(fallbackUrl);
    }
    if (data == null || data.isEmpty) return null;
    final cacheRoot = await getTemporaryDirectory();
    final artDirectory = Directory(
      '${cacheRoot.path}${Platform.pathSeparator}media_art',
    );
    if (!artDirectory.existsSync()) {
      await artDirectory.create(recursive: true);
    }
    final extension = _artworkExtension(data);
    final file = File(
      '${artDirectory.path}${Platform.pathSeparator}'
      '${sha256.convert(data)}.$extension',
    );
    if (!file.existsSync()) {
      await file.writeAsBytes(data, flush: true);
    }
    return file.uri;
  }

  /// 下载网络封面。失败一律走日志页而不是静默 —— 锁屏没封面最难查，
  /// 必须留下痕迹。`music.126.net` 需要 Referer，见 CoverImageSource.headersFor。
  Future<Uint8List?> _downloadArtwork(String? url) async {
    final normalized = url?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || !uri.isScheme('http')) return null;
    try {
      final client = HttpClient();
      try {
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 8));
        CoverImageSource.headersFor(normalized)?.forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          unawaited(
            AppLogger.write(
              'artwork',
              '下载失败 http=${response.statusCode} url=${_logSafeUrl(normalized)}',
            ),
          );
          return null;
        }
        final bytes = await _collectResponseBytes(
          response,
        ).timeout(const Duration(seconds: 12));
        // 只接受真正的图片，避免把错误页 HTML 当封面存进去。
        if (!_looksLikeImage(bytes)) {
          unawaited(
            AppLogger.write(
              'artwork',
              '响应不是图片 bytes=${bytes.length} url=${_logSafeUrl(normalized)}',
            ),
          );
          return null;
        }
        return bytes;
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      unawaited(
        AppLogger.write(
          'artwork',
          '下载异常 url=${_logSafeUrl(normalized)} error=$error',
        ),
      );
      return null;
    }
  }

  /// 手动收集响应体。
  ///
  /// `consolidateHttpClientResponseBytes` 在 `package:http` 里而不是 `dart:io`，
  /// 为一个封面下载多引一个包不值得，这里自己按块收集并加上限 ——
  /// 封面正常只有几十 KB，设 8 MB 上限防止异常响应把内存吃满。
  static Future<Uint8List> _collectResponseBytes(
    HttpClientResponse response,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > 8 * 1024 * 1024) {
        throw StateError('封面响应超过 8MB 上限');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 锁屏封面常见格式：PNG / JPEG / GIF / WebP。
  static bool _looksLikeImage(Uint8List bytes) {
    if (bytes.length < 4) return false;
    final b = bytes;
    // PNG: 89 50 4E 47   JPEG: FF D8 FF   GIF: 47 49 46   WEBP: RIFF....WEBP
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47)
      return true;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true;
    }
    return false;
  }

  /// 去掉查询串再记日志，避免把带签名的 URL 整条写进日志。
  static String _logSafeUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '(无法解析)';
    return '${uri.scheme}://${uri.host}${uri.path}';
  }

  @override
  Future<void> play() async {
    if (_trackTransitionActive) return;
    final pauseGeneration = _pauseGeneration;
    _logTransport('play');
    if (_player.processingState == BassProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    if (!_audioSessionConfigured) {
      await setAllowMixWithOthers(_allowMixWithOthers);
    }
    if (shouldActivatePlayerAudioSession(
      allowMixWithOthers: _allowMixWithOthers,
      isAndroid: Platform.isAndroid,
    )) {
      final session = await AudioSession.instance;
      final granted = await session.setActive(true);
      unawaited(AppLogger.write('audio-session', 'activate granted=$granted'));
      if (!granted) return;
    }
    if (pauseGeneration != _pauseGeneration) return;
    await _player.play();
  }

  @override
  Future<void> pause() => _pausePlayer();

  Future<void> _pausePlayer({
    bool preserveInterruptionResume = false,
    String reason = 'transport_callback',
  }) {
    _pauseGeneration++;
    if (!preserveInterruptionResume) _resumeAfterInterruption = false;
    _logTransport('pause', reason: reason);
    return _player.pause();
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    unawaited(AppLogger.write('player-control', 'media_button=${button.name}'));
    switch (button) {
      case MediaButton.media:
        if (_player.playing) {
          await _pausePlayer(reason: 'media_button');
        } else {
          await play();
        }
        return;
      case MediaButton.next:
        await skipToNext();
        return;
      case MediaButton.previous:
        await skipToPrevious();
        return;
    }
  }

  @override
  Future<void> seek(Duration position) {
    if (_trackTransitionActive) return Future<void>.value();
    _logTransport('seek', target: position);
    return _player.seek(position);
  }

  Future<void> setEqualizer(BassEqualizerConfiguration configuration) async {
    if (!_engineInitialized) {
      _pendingEqualizer = configuration;
      return;
    }
    await _player.setEqualizer(configuration);
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _onQueueItem?.call(index);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatMode = repeatMode;
    _broadcastState(_player.snapshot);
    await _onRepeatMode?.call(repeatMode);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffleMode = shuffleMode;
    _broadcastState(_player.snapshot);
    await _onShuffleMode?.call(shuffleMode);
  }

  @override
  Future<void> stop() async {
    _logTransport('stop');
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() async {
    _logTransport('task_removed');
    await super.onTaskRemoved();
    await AppLogger.flush();
  }

  @override
  Future<void> onNotificationDeleted() async {
    _logTransport('notification_deleted');
    await super.onNotificationDeleted();
    await AppLogger.flush();
  }

  Future<void> disposeHandler() async {
    await _playbackSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _player.dispose();
  }

  void _clearTransitionSnapshot() {
    _mediaItemBeforeTransition = null;
    _queueIndexBeforeTransition = null;
  }

  void _updateDuration(Duration? duration) {
    if (duration == null) return;
    final item = _currentMediaItem;
    if (item == null || item.duration == duration) return;
    _currentMediaItem = preserveMediaItemArtHeaders(
      item,
      item.copyWith(duration: duration),
    );
    mediaItem.add(_currentMediaItem);
  }

  void _broadcastError(Object error, StackTrace stackTrace) {
    unawaited(
      AppLogger.write(
        'player-error',
        'engine_error state=${_player.processingState.name} '
            'playing=${_player.playing} positionMs=${_player.position.inMilliseconds} '
            'bufferedMs=${_player.bufferedPosition.inMilliseconds} '
            'error=$error',
      ),
    );
    if (_trackTransitionActive) {
      playbackState.add(_transitionState(_player.snapshot));
      return;
    }
    playbackState.add(
      _transformEvent(_player.snapshot).copyWith(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: error.toString(),
      ),
    );
  }

  void _broadcastState(BassPlaybackSnapshot event) {
    playbackState.add(
      _trackTransitionActive ? _transitionState(event) : _transformEvent(event),
    );
  }

  PlaybackState _transitionState(BassPlaybackSnapshot event) {
    return _transformEvent(event).copyWith(
      processingState: AudioProcessingState.loading,
      playing: false,
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      queueIndex: _queueIndex,
    );
  }

  PlaybackState _transformEvent(BassPlaybackSnapshot event) {
    final hasItem = _currentMediaItem != null;
    final controls = hasItem
        ? <MediaControl>[
            MediaControl.skipToPrevious,
            if (_player.playing) MediaControl.pause else MediaControl.play,
            MediaControl.skipToNext,
          ]
        : const <MediaControl>[];
    return PlaybackState(
      controls: controls,
      androidCompactActionIndices: hasItem ? const [0, 1, 2] : null,
      systemActions: hasItem
          ? const {
              MediaAction.seek,
              MediaAction.seekForward,
              MediaAction.seekBackward,
              MediaAction.setRepeatMode,
              MediaAction.setShuffleMode,
            }
          : const {},
      processingState: switch (_player.processingState) {
        BassProcessingState.idle => AudioProcessingState.idle,
        BassProcessingState.loading => AudioProcessingState.loading,
        BassProcessingState.buffering => AudioProcessingState.buffering,
        BassProcessingState.ready => AudioProcessingState.ready,
        BassProcessingState.completed => AudioProcessingState.completed,
        BassProcessingState.error => AudioProcessingState.error,
      },
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _queueIndex,
      repeatMode: _repeatMode,
      shuffleMode: _shuffleMode,
    );
  }

  void _logTransport(String action, {Duration? target, String? reason}) {
    final extras = _currentMediaItem?.extras;
    final kind = extras?['trackKind']?.toString() ?? 'none';
    final source = extras?['source']?.toString() ?? 'none';
    final quality = extras?['quality']?.toString() ?? 'none';
    unawaited(
      AppLogger.write(
        'player-transport',
        'action=$action state=${_player.processingState.name} '
            'reason=${reason ?? 'transport_callback'} '
            'lifecycle=${WidgetsBinding.instance.lifecycleState?.name ?? 'unknown'} '
            'playing=${_player.playing} positionMs=${_player.position.inMilliseconds} '
            'targetMs=${target?.inMilliseconds ?? -1} '
            'kind=$kind source=$source quality=$quality',
      ),
    );
  }

  String _artworkExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return 'jpg';
  }
}

final playerAudioHandlerProvider = Provider<PlayerAudioHandler>((ref) {
  throw StateError('playerAudioHandlerProvider must be overridden at startup');
});
