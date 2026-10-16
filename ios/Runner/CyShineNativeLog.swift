// 原生 → Dart 的日志桥。
//
// 为什么需要它：原生的失败（实时活动发起被系统拒绝、备用图标切换失败……）
// 默认只能写 `NSLog`。Release 包上 NSLog 只进系统日志，不落 App 内的「日志」页 ——
// 真机排查时等于什么都看不见，只能看到 Dart 侧一句笼统的「推送失败」。
//
// 这里开一条独立通道把原生日志回灌给 Dart 的 AppLogger，
// 于是用户在 App 里就能直接读到「系统为什么拒绝」。
//
// 通道名 `cy_shine_music/native_log` 是 iOS 独有的新增通道，
// 不涉及任何已有的 Android 契约（通道名/方法名/字段名一律不动）。

import Flutter
import Foundation

final class CyShineNativeLog {

  static let channelName = "cy_shine_music/native_log"

  private static var channel: FlutterMethodChannel?

  /// 由 CyShineNativePlugin 在注册时调用。必须早于任何 write。
  static func register(with messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
  }

  /// 写一条日志到 App 内的「日志」页。
  ///
  /// tag 建议用 `live-activity` / `app-icon` 这类短标签，方便在日志页筛选。
  /// 允许从任意线程调用：MethodChannel 必须在主线程发起，这里自动切。
  static func write(_ tag: String, _ message: String) {
    guard let channel else {
      NSLog("[\(tag)] \(message)")
      return
    }
    let payload: [String: Any] = ["tag": tag, "message": message]
    if Thread.isMainThread {
      channel.invokeMethod("log", arguments: payload)
    } else {
      DispatchQueue.main.async { channel.invokeMethod("log", arguments: payload) }
    }
  }
}
