// CyShineMusic iOS —— 桌面音乐小组件桥。
//
// 与 Android 的 packages/music_home_widget 契约一致：
//   MethodChannel cy_shine_music/home_widget
//     Dart -> 原生：ready / openApp / update{trackId,title,artist,cover,headers}
//                   updatePlayback{playing,loading}
//     原生 -> Dart：control(action: toggle|previous|next) / openPlayer
//
// 架构差异（必须知道）：
//   Android 的卡片是 AppWidget，主 App 直接渲染 RemoteViews；
//   iOS 对应物是 WidgetKit Extension，跑在**独立进程**里，主 App 无法直接驱动它，
//   只能通过 App Group 的 UserDefaults 共享数据 + WidgetCenter.reloadAllTimelines()
//   通知刷新。因此这里的职责是：把 Dart 推来的播放状态写进 App Group，并触发刷新。
//   真正的卡片 UI 在 ios/CyShineMusicWidget/ 里。
//
// 注意：lib/features/player/music_home_widget_service.dart 目前有
// `if (!Platform.isAndroid) return;` 守卫，所以主 App 不会调用这里。
// 要让 iOS 小组件真正生效，需要把那个守卫放开为「Android 或 iOS」——
// 这一步记在 recon/IOS-PORT-INTERNALS.md 的「Dart 侧待改动」清单里。

import Flutter
import Foundation
import WidgetKit

public final class MusicHomeWidgetPlugin: NSObject, FlutterPlugin {

  static let channelName = "cy_shine_music/home_widget"

  /// 主 App 与 Widget Extension 共用的 App Group。
  /// 必须与 ios/Runner/Runner.entitlements、ios/CyShineMusicWidget/*.entitlements
  /// 以及 Xcode 里两个 target 的 App Groups capability 完全一致。
  static let appGroupIdentifier = "group.com.cyshine.music"

  /// App Group 内共享的键，Widget Extension 侧读同名键（见 CyShineWidgetStore.swift）。
  enum SharedKey {
    static let trackId = "widget.trackId"
    static let title = "widget.title"
    static let artist = "widget.artist"
    static let cover = "widget.cover"
    static let headers = "widget.headers"
    static let playing = "widget.playing"
    static let loading = "widget.loading"
    static let updatedAt = "widget.updatedAt"
  }

  private var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MusicHomeWidgetPlugin()
    let channel = FlutterMethodChannel(name: channelName,
                                       binaryMessenger: registrar.messenger())
    instance.channel = channel
    channel.setMethodCallHandler(instance.handle)
    registrar.publish(instance)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ready":
      // 与 Android 的 ready 语义一致：登记完成，允许开始推数据。
      result(nil)

    case "openApp":
      // iOS 上没有 Android 那样的「点卡片唤起 Activity」，小组件点击由
      // WidgetKit 的 widgetURL 处理；主 App 侧无需做事。
      result(nil)

    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(nil)
        return
      }
      writeTrack(args)
      reloadTimelines()
      result(nil)

    case "updatePlayback":
      let args = call.arguments as? [String: Any] ?? [:]
      writePlayback(playing: args["playing"] as? Bool ?? false,
                    loading: args["loading"] as? Bool ?? false)
      reloadTimelines()
      result(nil)

    case "isSupported":
      if #available(iOS 14.0, *) { result(true) } else { result(false) }

    case "reloadWidgets":
      reloadTimelines()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 写 App Group

  private func sharedDefaults() -> UserDefaults? {
    UserDefaults(suiteName: Self.appGroupIdentifier)
  }

  private func writeTrack(_ args: [String: Any]) {
    guard let defaults = sharedDefaults() else { return }
    defaults.set(args["trackId"] as? String ?? "", forKey: SharedKey.trackId)
    defaults.set(args["title"] as? String ?? "", forKey: SharedKey.title)
    defaults.set(args["artist"] as? String ?? "", forKey: SharedKey.artist)
    defaults.set(args["cover"] as? String ?? "", forKey: SharedKey.cover)
    let headers = args["headers"] as? [String: Any] ?? [:]
    defaults.set(headers.reduce(into: [String: String]()) { acc, entry in
      acc[entry.key] = String(describing: entry.value)
    }, forKey: SharedKey.headers)
    defaults.set(Date().timeIntervalSince1970, forKey: SharedKey.updatedAt)
  }

  private func writePlayback(playing: Bool, loading: Bool) {
    guard let defaults = sharedDefaults() else { return }
    defaults.set(playing, forKey: SharedKey.playing)
    defaults.set(loading, forKey: SharedKey.loading)
    defaults.set(Date().timeIntervalSince1970, forKey: SharedKey.updatedAt)
  }

  private func reloadTimelines() {
    if #available(iOS 14.0, *) {
      WidgetCenter.shared.reloadAllTimelines()
    }
  }
}
