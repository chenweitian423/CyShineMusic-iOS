import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  /// iOS 在「文件 App / 其他 App 分享 → 用栖弦打开」以及
  /// **点击实时活动卡片 / 灵动岛上的按钮**时都会走这里。
  /// 两个入口（这里与 AppDelegate 的 application(_:open:options:)）都接上，
  /// 避免不同系统版本走不同回调导致漏接。
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      let url = context.url
      if url.isFileURL {
        CyShineIncomingAudio.shared.accept(url: url)
      } else if url.scheme?.lowercased() == cyShineURLScheme {
        _ = CyShineIncomingAudio.handleAppURL(url)
      }
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
