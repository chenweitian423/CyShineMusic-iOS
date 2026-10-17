import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/app_logger.dart';
import '../../core/ui/cover_image_source.dart';
import 'player_audio_handler.dart';
import 'player_controller.dart';

/// 灵动岛 / 锁屏实时活动（Live Activity）的驱动。
///
/// 只在 iOS 上生效，且系统「设置 → 栖弦 → 实时活动」打开时才真正工作。
/// 原生实现见 ios/Runner/CyShineLiveActivityBridge.swift，
/// 渲染见 ios/CyShineMusicWidget/CyShineLiveActivityWidget.swift。
///
/// 更新频率刻意压得很低：只在**换歌 / 播放暂停 / 跳转**时推一次。
/// 进度条由原生侧的 `ProgressView(timerInterval:)` 自己推进，
/// 所以不需要每秒推更新。
final liveActivityProvider = Provider<LiveActivityService>((ref) {
  final service = LiveActivityService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// 与 `musicHomeWidgetSyncProvider` 同样的作用：声明它就开始跟随播放状态。
final liveActivitySyncProvider = Provider<void>((ref) {
  final service = ref.read(liveActivityProvider);
  ref.listen<PlayerState>(playerControllerProvider, (_, state) {
    service.publish(state);
  }, fireImmediately: true);
});

class LiveActivityService {
  LiveActivityService(this._ref);

  static const MethodChannel _channel = MethodChannel(
    'cy_shine_music/live_activity',
  );

  final Ref _ref;
  bool _available = false;
  bool _checking = false;
  bool _subscriptionsReady = false;
  String? _activeTrackId;
  String? _lastSignature;
  StreamSubscription<PlaybackState>? _playbackSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  Future<void> _queue = Future<void>.value();

  /// 点灵动岛 / 锁屏卡片时把播放器推到前台。
  Future<void> Function()? onOpenPlayer;

  Future<void> initialize() async {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    await _ensureAvailable();
  }

  /// 检查系统的实时活动开关。
  ///
  /// 刻意做成可以反复调用：用户可能先播放、才想起来去
  /// 「设置 → 栖弦 → 实时活动」打开开关 —— 只在启动时检查一次的话，
  /// 就得重启 App 才生效，表现成「灵动岛怎么都不出现」。
/// 每次播放状态变化都会重试一次，代价只是一次轻量通道调用。
  ///
  /// [force] 用于「通知授权刚被回答」这种外部状态变化的场景：
  /// 之前拿到过 false 而放弃了，必须强制重新判定一次。
  Future<void> _ensureAvailable({bool force = false}) async {
    if (!Platform.isIOS || (_available && !force) || _checking) return;
    _checking = true;
    try {
      final supported =
          await _channel.invokeMethod<bool>('isSupported') ?? false;
      if (!supported) {
        await AppLogger.write(
          'live-activity',
          '系统未开启实时活动（设置 → 栖弦 → 实时活动），暂不推送；开关打开后无需重启即可生效',
        );
        _available = false;
        return;
      }
      _available = true;
      _attachListeners();
      await AppLogger.write('live-activity', '实时活动已就绪');
    } on MissingPluginException {
      _available = false;
    } catch (error) {
      _available = false;
      await AppLogger.write('live-activity', '初始化失败: $error');
    } finally {
      _checking = false;
    }
  }

  void _attachListeners() {
    if (_subscriptionsReady) return;
    _subscriptionsReady = true;
    final handler = _ref.read(playerAudioHandlerProvider);
    // 播放传输走 playbackState，曲目变化走 playerController。
    _playbackSubscription = handler.playbackState.listen(_onPlaybackState);
    // 时长通常比播放状态晚一步解析出来，进度条要靠这次更新才会出现。
    _durationSubscription = handler.durationStream.listen(
      (_) => unawaited(_push(afterArtwork: false)),
    );
  }

  // MARK: - 原生回调

Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'control':
        final action = call.arguments as String? ?? '';
        // 串行化，避免连点灵动岛按钮时互相打断。
        _queue = _queue
            .then((_) => _control(action))
            .catchError((Object error) async {
              await AppLogger.write('live-activity', 'control 失败: $error');
            });
        return true;
      case 'openPlayer':
        await onOpenPlayer?.call();
        return true;
      case 'authorizationResolved':
        // 原生的通知授权弹窗刚被回答。此刻 areActivitiesEnabled 才翻成 true，
        // 立刻重新判定一次并把当前曲目推上去 —— 否则要等下一次播放状态变化
        // 才恢复，表现为「授权完了还是没反应，再播一次才有」。
        await _ensureAvailable(force: true);
        final state = _ref.read(playerControllerProvider);
        if (state.track != null) {
          _activeStarted = false;
          _lastSignature = null;
          await _push(afterArtwork: true);
        }
        return true;
    }
    throw MissingPluginException('未知的实时活动方法: ${call.method}');
  }

  Future<void> _control(String action) async {
    _ref.read(liveActivitySyncProvider);
    final player = _ref.read(playerControllerProvider.notifier);
    await player.waitForSessionRestore();
    if (!_ref.read(playerControllerProvider).hasTrack) {
      await onOpenPlayer?.call();
      return;
    }
    switch (action) {
      case 'toggle':
        await player.toggle();
      case 'previous':
        await player.playPrevious();
      case 'next':
        await player.playNext();
    }
    await AppLogger.write('live-activity', '控制: $action');
  }

  // MARK: - 状态推送

  /// 曲目变化（可能是换歌，也可能是首次播放）。
  void publish(PlayerState state) {
    if (!_available) {
      // 可能只是「实时活动开关后来才打开」，重试一次而不是永远放弃。
      unawaited(_ensureAvailable());
      return;
    }
    final track = state.track;
    if (track == null) {
      _end();
      return;
    }
    final changed = track.id != _activeTrackId;
    _activeTrackId = track.id;
    unawaited(_push(afterArtwork: changed));
  }

  void _onPlaybackState(PlaybackState state) {
    if (!_available) {
      unawaited(_ensureAvailable());
      return;
    }
    final playerState = _ref.read(playerControllerProvider);
    if (playerState.track == null) {
      _end();
      return;
    }
    final processing = state.processingState;
    final stopped =
        processing == AudioProcessingState.idle ||
        processing == AudioProcessingState.error;
    // 注意：completed 不停活动 —— 下一首马上会接着 start，
    // 停掉再建会让灵动岛闪一下。
    if (stopped && !state.playing) {
      _end();
      return;
    }
    unawaited(_push(afterArtwork: false));
  }

  /// 计算要推给原生的载荷。
  ///
  /// 返回 null 表示这次没有实质变化（比如进度回调），可以跳过，
  /// 避免把通道刷爆。
  Map<String, dynamic>? _payload() {
    final audioHandler = _ref.read(playerAudioHandlerProvider);
    final playback = audioHandler.playbackState.value;
    final state = _ref.read(playerControllerProvider);
    final track = state.track;
    if (track == null) return null;

    final playing =
        playback.playing &&
        playback.processingState != AudioProcessingState.idle &&
        playback.processingState != AudioProcessingState.completed &&
        playback.processingState != AudioProcessingState.error;
    final loading =
        playback.processingState == AudioProcessingState.loading ||
        playback.processingState == AudioProcessingState.buffering;

    // audio_service 的 updatePosition 是「上次更新时的位置」，
    // 播放中要按经过时间补上，否则进度条会一直落后。
    var positionMs = playback.updatePosition.inMilliseconds;
    if (playing) {
      final elapsed =
          DateTime.now().difference(playback.updateTime).inMilliseconds;
      if (elapsed > 0) positionMs += elapsed;
    }
    // 时长在 MediaItem 上，不在 PlaybackState 上；而且往往播放开始后才解析出来，
    // 所以这里每次都重新读，解析到之后会通过 durationStream 再推一次更新。
    final durationMs = audioHandler.duration?.inMilliseconds ??
        audioHandler.mediaItem.value?.duration?.inMilliseconds ??
        0;
    if (positionMs < 0) positionMs = 0;
    if (durationMs > 0 && positionMs > durationMs) positionMs = durationMs;

    return {
      'trackId': track.id,
      'title': track.title,
      'artist': track.artist,
      'durationMs': durationMs,
      'positionMs': positionMs,
      'playing': playing,
      'loading': loading,
    };
  }

  Future<void> _push({required bool afterArtwork}) async {
    if (!_available) return;
    final payload = _payload();
    if (payload == null) return;

    // 只有「换歌 / 播放状态变化 / 明显跳转」才值得推一次更新。
    // 位置量化到 5 秒，避免连续微调把通道刷爆；seek 会直接改变量化后的值。
    final signature = [
      payload['trackId'],
      payload['playing'],
      (payload['positionMs'] as int) ~/ 5000,
      payload['durationMs'],
    ].join('|');
    // 首帧（换歌）必须推一次，哪怕签名"看起来"没变。
    if (!afterArtwork && _activeStarted && signature == _lastSignature) return;
    _lastSignature = signature;

    try {
      final method = _activeStarted ? 'update' : 'start';
      await _channel.invokeMethod<dynamic>(method, {
        ...payload,
        ...await _coverPayload(),
      });
      _activeStarted = true;
    } on MissingPluginException {
      _available = false;
    } catch (error) {
      await AppLogger.write('live-activity', '推送失败: $error');
    }
  }

  bool _activeStarted = false;

  Future<Map<String, dynamic>> _coverPayload() async {
    try {
      final track = _ref.read(playerControllerProvider).track;
      final embedded = await _ref
          .read(playerAudioHandlerProvider)
          .cacheArtwork(track?.coverBytes);
      final cover =
          embedded?.toString() ??
          CoverImageSource.normalizeUrl(track?.coverUrl, size: 512) ??
          '';
      return {'cover': cover, 'headers': CoverImageSource.headersFor(cover) ?? {}};
    } catch (error) {
      await AppLogger.write('live-activity', '封面处理失败: $error');
      return {'cover': '', 'headers': <String, String>{}};
    }
  }

  void _end() {
    if (!_available || !_activeStarted) return;
    _activeStarted = false;
    _activeTrackId = null;
    _lastSignature = null;
    unawaited(
      _channel.invokeMethod<void>('end').catchError((Object error) async {
        await AppLogger.write('live-activity', '结束活动失败: $error');
      }),
    );
  }

  void dispose() {
    _end();
    unawaited(_playbackSubscription?.cancel());
    _playbackSubscription = null;
    unawaited(_durationSubscription?.cancel());
    _durationSubscription = null;
  }
}
