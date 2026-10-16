import Flutter
import UIKit

/// 实时活动 / 桌面小组件的深链 scheme。
/// 与 ios/CyShineMusicWidget/Info.plist 的 CFBundleURLTypes 保持一致。
let cyShineURLScheme = "cyshinemusic"

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 注册 Runner 侧自带的 6 个通道（app_icon / media_scan / storage_browser /
    // audio_intent / native_tagger / app_task）。这些不经过 pub 插件机制，
    // 所以必须在这里手动登记，否则 Dart 侧会拿到 MissingPluginException。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CyShineNativePlugin") {
      CyShineNativePlugin.register(with: registrar)
    }

    // 实时活动（灵动岛）/ 桌面小组件的桥接。
    // ActivityKit 需要 iOS 16.1+；Runner 的部署目标已是 16.1，这里再判一次
    // 是为了让代码在更低的部署目标下也能编译。
    if #available(iOS 16.1, *),
       let registrar = engineBridge.pluginRegistry
        .registrar(forPlugin: "CyShineLiveActivityBridge") {
      CyShineLiveActivityBridge.register(with: registrar.messenger())
    }
  }

  /// 老式（无 Scene）路径下的 URL 回跳：文件分享与 `cyshinemusic://` 深链。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.isFileURL {
      CyShineIncomingAudio.shared.accept(url: url)
      return true
    }
    if url.scheme?.lowercased() == cyShineURLScheme {
      return CyShineIncomingAudio.handleAppURL(url)
    }
    return super.application(app, open: url, options: options)
  }
}
