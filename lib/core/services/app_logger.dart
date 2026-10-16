import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// File-backed log so the user can hand over a real trace when something
// looks wrong. Each line is `ISO8601 [scope] message`, persisted to
// `<app-documents>/logs/cyshine.log` (rotated at 1 MiB).
class AppLogger {
  const AppLogger._();

  static final _live = StreamController<String>.broadcast(sync: false);
  static final List<String> _recent = <String>[];
  static File? _file;
  static IOSink? _sink;
  static Future<void>? _initFuture;
  static const _maxBytes = 1024 * 1024;
  static const _maxRecentLines = 500;
  static final sessionId = '${DateTime.now().microsecondsSinceEpoch}-$pid';
  static String _environment = 'environment=unavailable';
  static String _androidDiagnostics = 'unavailable';
  static String _iosDiagnostics = 'unavailable';

  static Future<void> logEnvironment() async {
    final environment = <String, Object?>{
      'platform': Platform.operatingSystem,
      'os': Platform.operatingSystemVersion,
      'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
      'timezone': DateTime.now().timeZoneName,
      'utcOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
    };
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 2),
      );
      environment.addAll({
        'app': info.appName,
        'package': info.packageName,
        'version': info.version,
        'build': info.buildNumber,
      });
    } catch (error) {
      environment['packageInfoError'] = error.toString();
    }
    _environment = jsonEncode(environment);
    await write('app-session', 'start session=$sessionId environment=$_environment');
    await logAndroidDiagnostics('startup');
  }

  /// 方法名沿用上游（改名字会平添一处 rebase 冲突），但两端都跑：
  /// 原生 `cy_shine_music/app_task.diagnostics` 在 Android 与 iOS 上都已经实现，
  /// 上游只是没给 iOS 开门。放开后日志页能直接看到
  /// 机型 / 系统版本 / 通知开关 / 低电量模式 —— 排查「灵动岛为什么不显示」时，
  /// 「通知开关」这一项尤其关键（见 CyShineLiveActivityBridge 的说明）。
  static Future<void> logAndroidDiagnostics(String reason) async {
    final scope = Platform.isAndroid
        ? 'android-runtime'
        : (Platform.isIOS ? 'ios-runtime' : null);
    if (scope == null) return;
    final String json;
    try {
      final data = await const MethodChannel('cy_shine_music/app_task')
          .invokeMapMethod<String, dynamic>('diagnostics')
          .timeout(const Duration(seconds: 2));
      json = jsonEncode(data);
    } catch (error) {
      await write(scope, 'reason=$reason unavailable=$error');
      return;
    }
    if (Platform.isIOS) {
      _iosDiagnostics = json;
    } else {
      _androidDiagnostics = json;
    }
    await write(scope, 'reason=$reason data=$json');
  }

  static String exportText(List<String> lines) =>
      '${DateTime.now().toIso8601String()} [log-export] session=$sessionId '
      'pid=$pid environment=$_environment '
      'lastAndroidSnapshot=$_androidDiagnostics '
      'lastIosSnapshot=$_iosDiagnostics\n${lines.join('\n')}';

  static Future<void> _ensureInit() => _initFuture ??= _initialize();

  static Future<void> _initialize() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'logs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(p.join(dir.path, 'cyshine.log'));
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        final backup = File(p.join(dir.path, 'cyshine.prev.log'));
        if (backup.existsSync()) backup.deleteSync();
        file.renameSync(backup.path);
      }
      _file = file;
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    } catch (_) {
      // Persistence is best-effort; console logging still works.
    }
  }

  static Future<void> write(String scope, String message) async {
    final line = '${DateTime.now().toIso8601String()} [$scope] $message';
    developer.log(message, name: 'lx.$scope');
    _remember(line);
    await _ensureInit();
    // Write into the sink before completing so a following flush includes it.
    try {
      _sink?.writeln(line);
    } catch (_) {}
  }

  static Stream<String> get liveLines => _live.stream;

  static List<String> get recentMemoryLines => List.unmodifiable(_recent);

  static Future<List<String>> readRecentLines({int limit = 400}) async {
    await _ensureInit();
    try {
      final file = _file;
      if (file == null || !file.existsSync()) {
        return _tail(_recent, limit);
      }
      await flush();
      final lines = await file.readAsLines();
      return _tail(lines, limit);
    } catch (_) {
      return _tail(_recent, limit);
    }
  }

  static Future<void> clear() async {
    await _ensureInit();
    try {
      await _sink?.flush();
      await _sink?.close();
      final file = _file;
      if (file != null) {
        await file.writeAsString('');
        _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
      }
      _recent.clear();
    } catch (_) {}
  }

  static Future<File?> currentLogFile() async {
    await _ensureInit();
    return _file;
  }

  static Future<void> flush() async {
    await _ensureInit();
    await _sink?.flush();
  }

  static void _remember(String line) {
    _recent.add(line);
    if (_recent.length > _maxRecentLines) {
      _recent.removeRange(0, _recent.length - _maxRecentLines);
    }
    if (!_live.isClosed) _live.add(line);
  }

  static List<String> _tail(List<String> lines, int limit) {
    if (lines.length <= limit) return List<String>.of(lines);
    return lines.sublist(lines.length - limit);
  }
}
