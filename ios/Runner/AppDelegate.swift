import Flutter
import UIKit

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
  }

  /// 老式（无 Scene）路径下的「用其他 App 打开文件」回调。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.isFileURL {
      CyShineIncomingAudio.shared.accept(url: url)
      return true
    }
    return super.application(app, open: url, options: options)
  }
}
