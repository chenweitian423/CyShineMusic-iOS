import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

  /// iOS 在「文件 App / 其他 App 分享 → 用栖弦打开」时走这里。
  /// 真正的短路径是 AppDelegate 的 application(_:open:options:)；两个都接上，
  /// 避免不同系统版本走不同回调导致漏接。
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts where context.url.isFileURL {
      CyShineIncomingAudio.shared.accept(url: context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
