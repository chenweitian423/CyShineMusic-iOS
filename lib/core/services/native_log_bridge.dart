import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 原生 → Dart 的日志桥（通道 `cy_shine_music/native_log`）。
///
/// 原生侧的失败（实时活动、备用图标、音源运行时……）默认只写 `NSLog`，
/// Release 包上不会出现在 App 内的「日志」页，真机排查等于盲区。
/// 原生通过这条通道把关键信息回灌进来，统一落到 [AppLogger]。
///
/// iOS 独有的通道，不涉及任何已有的 Android 契约。
class NativeLogBridge {
  const NativeLogBridge._();

  static const MethodChannel _channel = MethodChannel(
    'cy_shine_music/native_log',
  );

  /// 在 `main()` 里尽早调用。
  static void install() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'log') return null;
      final args = call.arguments;
      if (args is Map) {
        final tag = args['tag']?.toString() ?? 'native';
        final message = args['message']?.toString() ?? '';
        if (message.isNotEmpty) await AppLogger.write(tag, message);
      }
      return null;
    });
  }
}
