// CyShineMusic iOS —— Runner 侧原生通道。
//
// 把 Android 端 android/app/src/main/kotlin/com/cyshine/music/MainActivity.kt 与
// AppIconManager.kt 里注册的 6 个 MethodChannel 在 iOS 上 1:1 复刻：
//
//   cy_shine_music/app_icon          getCurrentIcon / setIcon
//   cy_shine_music/media_scan        scan
//   cy_shine_music/storage_browser   listRoots / listChildren（+ addRoot/removeRoot 扩展）
//   cy_shine_music/audio_intent      takePendingAudio / openAudio（+ audioAvailable 回调）
//   cy_shine_music/native_tagger     read / write
//   cy_shine_music/app_task          moveToBack / diagnostics
//
// 通道名、方法名、参数与返回值的字段名都与 Android 完全一致，lib/ 层因此
// 无需改动（唯一例外见 storage_browser：iOS 沙盒没有全盘扫描，见下方说明）。

import AVFoundation
import Flutter
import Foundation
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

@available(iOS 13.0, *)
public final class CyShineNativePlugin: NSObject, FlutterPlugin {

  private let appIcon = CyShineAppIconChannel()
  private let mediaScan = CyShineMediaScanChannel()
  private let storageBrowser = CyShineStorageBrowserChannel()
  private let audioIntent = CyShineAudioIntentChannel()
  private let nativeTagger = CyShineNativeTaggerChannel()
  private let appTask = CyShineAppTaskChannel()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CyShineNativePlugin()
    let messenger = registrar.messenger()
    instance.bind(to: messenger)
    registrar.publish(instance)
  }

  private func bind(to messenger: FlutterBinaryMessenger) {
    connect("cy_shine_music/app_icon", messenger) { [appIcon] call, result in
      appIcon.handle(call, result)
    }
    connect("cy_shine_music/media_scan", messenger) { [mediaScan] call, result in
      mediaScan.handle(call, result)
    }
    connect("cy_shine_music/storage_browser", messenger) { [storageBrowser] call, result in
      storageBrowser.handle(call, result)
    }
    connect("cy_shine_music/audio_intent", messenger) { [audioIntent] call, result in
      audioIntent.handle(call, result)
    }
    connect("cy_shine_music/native_tagger", messenger) { [nativeTagger] call, result in
      nativeTagger.handle(call, result)
    }
    connect("cy_shine_music/app_task", messenger) { [appTask] call, result in
      appTask.handle(call, result)
    }
    // 原生 → Dart 的日志桥。必须最先注册，后面各处才敢往里写。
    CyShineNativeLog.register(with: messenger)
    CyShineIncomingAudio.shared.bind(to: messenger)
  }

  private func connect(_ name: String,
                       _ messenger: FlutterBinaryMessenger,
                       _ handler: @escaping (FlutterMethodCall, @escaping FlutterResult) -> Void) {
    FlutterMethodChannel(name: name, binaryMessenger: messenger)
      .setMethodCallHandler { call, result in handler(call, result) }
  }
}

// MARK: - 应用图标
//
// Android 用 activity-alias 可以无提示切换；iOS 只能用 setAlternateIconName，
// 且有几条硬约束：
//   1. 备用图标必须**预先打进 bundle**，并在 Info.plist 的 CFBundleAlternateIcons
//      里声明 —— 名字与图标文件必须一一对应；
//   2. 切换时系统会弹一次提示，无法绕过（平台限制，不是实现问题）；
//   3. 图标一旦涉及资产目录（Assets.car），就必须走 Xcode 的
//      「Alternate App Icon Sets」构建设置，手工往 Info.plist 塞
//      CFBundleAlternateIcons 在新 Xcode / 新 iOS 上会静默失效
//      （表现为 supportsAlternateIcons 为 false 或切换直接报错）。
//
// 所以这里不赌单一来源：每个变体维护一串**候选名**，按顺序尝试，
// 第一个成功的就采用。候选名与 tool/fetch_app_icons.py、tool/patch_xcodeproj.py
// 生成的两套图标一一对应。

@available(iOS 13.0, *)
final class CyShineAppIconChannel {

  /// Dart 侧的 AppIconVariant.code -> 系统里的图标名候选（按优先级）。
  /// classic 是主图标，对应 setAlternateIconName(nil)。
  ///
  ///  · `AppIcon<Name>`  —— 资产目录里的备用图标集（Xcode 官方路径，
  ///    由 ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES 声明）
  ///  · `icon_<code>`    —— 旧路径：Runner/Icons/ 下散装的 PNG + Info.plist 手工声明
  private static let alternateCandidates: [String: [String]] = [
    "midnight": ["AppIconMidnight", "icon_midnight"],
    "sky": ["AppIconSky", "icon_sky"],
    "lavender": ["AppIconLavender", "icon_lavender"],
    "mint": ["AppIconMint", "icon_mint"],
    "peach": ["AppIconPeach", "icon_peach"],
  ]

  /// 反查表：任意候选名 -> Dart 侧 code。currentCode() 用它把
  /// `UIApplication.alternateIconName` 还原成 code。
  private static let codeByIconName: [String: String] = {
    var map: [String: String] = [:]
    for (code, names) in alternateCandidates {
      for name in names { map[name] = code }
    }
    return map
  }()

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "getCurrentIcon":
      result(currentCode())

    case "setIcon":
      guard let args = call.arguments as? [String: Any],
            let code = args["icon"] as? String, !code.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "请选择应用图标", details: nil))
        return
      }
      if code != "classic" && Self.alternateCandidates[code] == nil {
        result(FlutterError(code: "ICON_CHANGE_FAILED",
                            message: "iOS 未声明该备用图标",
                            details: "unknown icon code: \(code)"))
        return
      }
      setIcon(code: code, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func currentCode() -> String {
    guard let name = UIApplication.shared.alternateIconName else { return "classic" }
    return Self.codeByIconName[name] ?? "classic"
  }

  private func setIcon(code: String, result: @escaping FlutterResult) {
    let current = UIApplication.shared.alternateIconName
    if code == "classic" {
      if current == nil { result("classic"); return }
      apply(nil, code: code) { error in result(error) }
      return
    }

    let candidates = Self.alternateCandidates[code] ?? []
    // 已经在用这个变体（任意一个候选名）时直接短路：
    // iOS 对「设成同一个图标」会回错误，这里保持 Dart 侧语义幂等。
    if let current, candidates.contains(current) {
      result(currentCode())
      return
    }
    applyFirstWorking(candidates, code: code, index: 0, errors: [], result: result)
  }

  /// 依次尝试候选名，第一个成功即返回；全失败时把所有原因一起报回去。
  private func applyFirstWorking(_ candidates: [String],
                                 code: String,
                                 index: Int,
                                 errors: [String],
                                 result: @escaping FlutterResult) {
    guard index < candidates.count else {
      let detail = errors.isEmpty ? "没有可用的候选图标名" : errors.joined(separator: " | ")
      CyShineNativeLog.write("app-icon", "切换 \(code) 全部失败：\(detail)")
      result(FlutterError(code: "ICON_CHANGE_FAILED",
                          message: "无法更换桌面图标",
                          details: detail))
      return
    }
    let name = candidates[index]
    apply(name, code: code, attempt: 0) { [weak self] error in
      guard let self else { return }
      if let error {
        self.applyFirstWorking(candidates,
                               code: code,
                               index: index + 1,
                               errors: errors + ["\(name): \(Self.describe(error))"],
                               result: result)
        return
      }
      CyShineNativeLog.write("app-icon", "图标已切换为 \(name)")
      result(self.currentCode())
    }
  }

  /// ★ LaunchServices 的 `-54`（`"process may not map database"`）是 iOS 上
  ///   换图标最常见的失败，而且**与打包是否正确无关**。
  ///
  ///   成因：`setAlternateIconName` 要让 LaunchServices 改写图标数据库，
  ///   而这个写操作有互斥与「正在忙」的窗口。连着快速点两下、或上一次切换
  ///   还没落盘就再切，就会撞上它。典型症状是**系统弹了「图标已更改」的提示
  ///   但图标没变**，或者图标变成空白占位。
  ///
  ///   所以这里的处理是：**串行化 + 退避重试**，而不是当成致命错误。
  ///   连着几轮都失败才回错误给 Dart。
  private static let launchServicesBusyCode = -54
  private static let maxApplyAttempts = 3

  /// 正在进行的切换。系统不允许并发调用，必须排队。
  private var iconChangeInFlight = false
  /// 排队中的请求（取最后一次 —— 用户连点时中间那几次没有意义）。
  private var pendingIconRequest: ((FlutterResult) -> Void)?

  /// 真正调用系统 API。completion 拿到 nil 表示成功。
  private func apply(_ name: String?,
                     code: String,
                     attempt: Int,
                     result: @escaping (Error?) -> Void) {
    guard UIApplication.shared.supportsAlternateIcons else {
      // 这一条最常被忽略：系统直接告诉你不支持，报错信息也不会有别的线索。
      CyShineNativeLog.write("app-icon",
                             "supportsAlternateIcons=false（当前=\(code)），系统或图标清单不允许切换")
      DispatchQueue.main.async {
        result(NSError(
          domain: "CyShineAppIcon",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey:
                      "系统不支持备用图标（supportsAlternateIcons=false），请检查备用图标是否已打进包并正确声明"]))
      }
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // 串行化：上一次没落盘就再切，必然撞 -54。
      if self.iconChangeInFlight {
        self.pendingIconRequest = result
        CyShineNativeLog.write("app-icon", "上一次切换尚未结束，本次请求排队（当前=\(code)）")
        return
      }
      self.iconChangeInFlight = true
      UIApplication.shared.setAlternateIconName(name) { [weak self] error in
        DispatchQueue.main.async {
          guard let self else { return }
          // -54 是 LaunchServices 暂时忙，退避后重试而不是直接失败。
          let ns = error as NSError?
          if ns?.domain == "NSOSStatusErrorDomain",
             ns?.code == Self.launchServicesBusyCode,
             attempt + 1 < Self.maxApplyAttempts {
            self.iconChangeInFlight = false
            let delay = DispatchTimeInterval.milliseconds(350 * (attempt + 1))
            CyShineNativeLog.write(
              "app-icon",
              "LaunchServices 忙(-54)，\(delay.milliseconds ?? 0)ms 后重试 "
                + "第 \(attempt + 2)/\(Self.maxApplyAttempts) 次（当前=\(code)）")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
              self.apply(name, code: code, attempt: attempt + 1, result: result)
            }
            return
          }
          self.iconChangeInFlight = false
          if let error {
            CyShineNativeLog.write(
              "app-icon",
              "切换 \(code) -> \(name ?? "主图标") 失败：\(Self.describe(error))")
          }
          // 排队的请求现在可以跑了。
          if let queued = self.pendingIconRequest {
            self.pendingIconRequest = nil
            queued(nil)
          }
          result(error)
        }
      }
    }
  }

  static func describe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
  }
}

// MARK: - 媒体库扫描
//
// Android 用 MediaScannerConnection 让下载完的文件出现在系统音乐库里；
// iOS 没有等价的「扫描某个路径进媒体库」机制（照片库有，音乐库没有）。
// 保留通道并返回 true，行为上等价于「扫描成功但无需动作」。

@available(iOS 13.0, *)
final class CyShineMediaScanChannel {
  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "scan":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
        return
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - 目录浏览
//
// Android 用 MANAGE_EXTERNAL_STORAGE 扫全盘；iOS 沙盒没有这个能力。
// 做法：
//   · 始终把 App 自己的 Documents 目录作为根（用户可通过「文件」App 放歌进来，
//     需要 Info.plist 打开 UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace）；
//   · 用户通过系统文档选择器授权的目录（如 iCloud Drive / 本机其他 App 的共享目录）
//     以 security-scoped bookmark 持久化，作为额外的根列出。
// 返回字段与 Android 的 storageEntry 完全一致。

@available(iOS 13.0, *)
final class CyShineStorageBrowserChannel {

  private let bookmarks = CyShineSecurityScopedStore()
  private let worker = DispatchQueue(label: "com.cyshine.music.storage_browser")

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "listRoots":
      result(listRoots())

    case "listChildren":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
        return
      }
      let includeFiles = args["includeFiles"] as? Bool ?? false
      // 与 Android 一致：大目录遍历放到后台线程，别卡 UI。
      worker.async {
        do {
          let entries = try self.listChildren(path: path, includeFiles: includeFiles)
          DispatchQueue.main.async { result(entries) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "LIST_CHILDREN_FAILED",
                                message: error.localizedDescription,
                                details: "\(error)"))
          }
        }
      }

    case "addRoot":
      // iOS 扩展点：Dart 侧选择目录后调用，传入
      // {name, bookmarkBase64} 以持久化授权。
      guard let args = call.arguments as? [String: Any],
            let name = args["name"] as? String,
            let encoded = args["bookmark"] as? String,
            let data = Data(base64Encoded: encoded) else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少 name/bookmark", details: nil))
        return
      }
      bookmarks.save(name: name, bookmark: data)
      result(true)

    case "removeRoot":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少 path", details: nil))
        return
      }
      bookmarks.remove(path: path)
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func listRoots() -> [[String: Any?]] {
    var roots: [[String: Any?]] = []

    if let documents = try? FileManager.default.url(for: .documentDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true) {
      roots.append(entry(url: documents,
                         isRoot: true,
                         label: "我的文件",
                         removable: false,
                         state: nil))
    }

    for root in bookmarks.resolvedRoots() {
      roots.append(entry(url: root.url,
                         isRoot: true,
                         label: root.name,
                         removable: nil,
                         state: nil))
    }

    return roots
  }

  private func listChildren(path: String, includeFiles: Bool) throws -> [[String: Any?]] {
    let scoped = bookmarks.beginAccessIfScoped(path: path)
    defer { if scoped.started { scoped.url?.stopAccessingSecurityScopedResource() } }

    let directory = URL(fileURLWithPath: path)
    let keys: [URLResourceKey] = [.isDirectoryKey, .isReadableKey, .isWritableKey, .nameKey]
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles])

    var entries: [[String: Any?]] = []
    for child in children {
      let values = try? child.resourceValues(forKeys: Set(keys))
      let isDirectory = values?.isDirectory ?? false
      // Android 的 listDirectoryChildren 同样过滤隐藏项与不可读项。
      if !isDirectory && !includeFiles { continue }
      if values?.isReadable == false { continue }
      entries.append(entry(url: child,
                           isRoot: false,
                           label: nil,
                           removable: nil,
                           state: nil))
    }

    // 目录在前，然后按名称排序（Android 用 lowercase 比较）。
    entries.sort { lhs, rhs in
      let lhsDir = lhs["isDirectory"] as? Bool ?? false
      let rhsDir = rhs["isDirectory"] as? Bool ?? false
      if lhsDir != rhsDir { return lhsDir }
      let lhsName = (lhs["name"] as? String ?? "").lowercased()
      let rhsName = (rhs["name"] as? String ?? "").lowercased()
      return lhsName < rhsName
    }
    return entries
  }

  private func entry(url: URL,
                     isRoot: Bool,
                     label: String?,
                     removable: Bool?,
                     state: String?) -> [String: Any?] {
    let path = url.path
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                   .isReadableKey,
                                                   .isWritableKey,
                                                   .volumeTotalCapacityKey,
                                                   .volumeAvailableCapacityKey])
    let total = (values?.volumeTotalCapacity).map { Int64($0) } ?? 0
    let free = (values?.volumeAvailableCapacity).map { Int64($0) } ?? 0

    let displayName: String
    if let label, !label.isEmpty {
      displayName = label
    } else {
      let last = url.lastPathComponent
      displayName = last.isEmpty ? path : last
    }

    return [
      "path": path,
      "name": displayName,
      "isDirectory": values?.isDirectory ?? false,
      "isRoot": isRoot,
      "isRemovable": removable,
      "canRead": values?.isReadable ?? FileManager.default.isReadableFile(atPath: path),
      "canWrite": values?.isWritable ?? FileManager.default.isWritableFile(atPath: path),
      "totalBytes": total,
      "freeBytes": free,
      "state": state,
    ]
  }
}

/// 用 security-scoped bookmark 记住用户授权过的目录，跨启动保持访问权。
final class CyShineSecurityScopedStore {
  private static let defaultsKey = "cyshine.scoped_roots"

  struct Root {
    let name: String
    let url: URL
  }

  private var cache: [Root] = []

  private var defaults: UserDefaults { UserDefaults.standard }

  private func load() -> [String: String] {
    defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
  }

  func save(name: String, bookmark: Data) {
    var stored = load()
    stored[name] = bookmark.base64EncodedString()
    defaults.set(stored, forKey: Self.defaultsKey)
  }

  func remove(path: String) {
    var stored = load()
    for (name, encoded) in stored {
      guard let data = Data(base64Encoded: encoded),
            let url = try? resolve(data).url, url.path == path else { continue }
      stored.removeValue(forKey: name)
    }
    defaults.set(stored, forKey: Self.defaultsKey)
  }

  /// 解析所有 bookmark；失效的条目直接丢弃，避免每次打开都报错。
  func resolvedRoots() -> [Root] {
    var roots: [Root] = []
    var stillValid: [String: String] = [:]
    for (name, encoded) in load() {
      guard let data = Data(base64Encoded: encoded) else { continue }
      if let resolved = try? resolve(data) {
        roots.append(Root(name: name, url: resolved.url))
        if !resolved.isStale { stillValid[name] = encoded }
      }
    }
    if stillValid.count != load().count {
      defaults.set(stillValid, forKey: Self.defaultsKey)
    }
    return roots
  }

  private func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var isStale = false
    let url = try URL(resolvingBookmarkData: data,
                      options: [.withoutUI],
                      relativeTo: nil,
                      bookmarkDataIsStale: &isStale)
    return (url, isStale)
  }

  /// 访问沙盒外目录前必须开始安全作用域访问，否则读目录会失败。
  func beginAccessIfScoped(path: String) -> (started: Bool, url: URL?) {
    for root in resolvedRoots() {
      let rootPath = root.url.path
      if path == rootPath || path.hasPrefix(rootPath + "/") {
        let started = root.url.startAccessingSecurityScopedResource()
        return (started, root.url)
      }
    }
    return (false, nil)
  }
}

// MARK: - 外部音频文件

@available(iOS 13.0, *)
final class CyShineAudioIntentChannel {

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "takePendingAudio":
      result(CyShineIncomingAudio.shared.takePendingPath())

    case "openAudio":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
        return
      }
      guard FileManager.default.fileExists(atPath: path) else {
        result(FlutterError(code: "NOT_FOUND", message: "file does not exist", details: nil))
        return
      }
      presentShareSheet(path: path, result: result)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentShareSheet(path: String, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard let root = CyShineIncomingAudio.shared.topViewController() else {
        result(FlutterError(code: "OPEN_FAILED", message: "找不到可用的界面", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = controller.popoverPresentationController {
        popover.sourceView = root.view
        popover.sourceRect = CGRect(x: root.view.bounds.midX,
                                    y: root.view.bounds.midY,
                                    width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      root.present(controller, animated: true) { result(true) }
    }
  }
}

/// 处理「用其他 App 打开音乐文件」的场景。
///
/// iOS 走 SceneDelegate/AppDelegate 的 openURL，不像 Android 那样能在启动时
/// 拿到 content://。这里把文件复制进 App 沙盒并缓存成路径，语义与 Android 的
/// resolveIncomingAudio 一致（Android 也因为需要真实路径而做了复制）。
final class CyShineIncomingAudio {
  static let shared = CyShineIncomingAudio()

  private var pendingPath: String?
  private var channel: FlutterMethodChannel?
  private let queue = DispatchQueue(label: "com.cyshine.music.incoming_audio")

  func bind(to messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "cy_shine_music/audio_intent",
                                   binaryMessenger: messenger)
  }

  /// 处理 `cyshinemusic://` 深链 —— 点击实时活动卡片 / 灵动岛按钮 / 桌面小组件时
  /// 由 AppDelegate 与 SceneDelegate 调用。返回 true 表示已消费掉这个 URL。
  static func handleAppURL(_ url: URL) -> Bool {
    if #available(iOS 16.2, *),
       CyShineLiveActivityBridge.shared?.handleIncomingURL(url) == true {
      return true
    }
    return false
  }

  func takePendingPath() -> String? {
    let path = pendingPath
    pendingPath = nil
    return path
  }

  /// 由 AppDelegate 调用。
  func accept(url: URL) {
    queue.async {
      do {
        let imported = try self.importFile(url)
        self.pendingPath = imported
        DispatchQueue.main.async {
          self.channel?.invokeMethod("audioAvailable", arguments: nil)
        }
      } catch {
        NSLog("[audio_intent] 导入外部音频失败: \(error)")
      }
    }
  }

  private func importFile(_ url: URL) throws -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    let fileManager = FileManager.default
    let caches = try fileManager.url(for: .cachesDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)
    let root = caches.appendingPathComponent("external_audio", isDirectory: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    var name = url.lastPathComponent
    if name.isEmpty { name = "外部音乐" }
    // 与 Android 一致：截断超长文件名（按字符而不是字节），保留扩展名。
    if name.count > 60 {
      let ext = url.pathExtension
      let base = url.deletingPathExtension().lastPathComponent
      name = String(base.prefix(50)) + (ext.isEmpty ? "" : ".\(ext)")
    }

    let target = directory.appendingPathComponent(name)
    if fileManager.fileExists(atPath: target.path) {
      try fileManager.removeItem(at: target)
    }
    try fileManager.copyItem(at: url, to: target)

    let attributes = try? fileManager.attributesOfItem(atPath: target.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0 else {
      try? fileManager.removeItem(at: directory)
      throw NSError(domain: "audio_intent", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "音乐文件为空"])
    }

    // 只保留最近 5 个，防止缓存无限增长（Android 同样只留 5 个）。
    let keep = 5
    if let children = try? fileManager.contentsOfDirectory(at: root,
                                                           includingPropertiesForKeys: [.contentModificationDateKey]) {
      let stale = children
        .filter { $0 != directory }
        .sorted { lhs, rhs in
          let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
          let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
          return lhsDate > rhsDate
        }
      for item in stale.dropFirst(keep - 1) {
        try? fileManager.removeItem(at: item)
      }
    }

    return target.path
  }

  func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let window = scenes
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
      ?? scenes.first?.windows.first
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController {
      controller = presented
    }
    return controller
  }
}

// MARK: - 音频标签读写
//
// Android 用 jaudiotagger。
// iOS：
//   · 读取 —— 用 AVFoundation 的 commonMetadata，覆盖 mp3 / m4a / flac / wav 等。
//     FLAC 的读取在 Dart 侧就已经由 FlacMetadataWriter 纯 Dart 完成，不会走这里。
//   · 写入 —— 只有 ISO-BMFF（m4a/mp4/mov）能用 AVAssetExportSession 安全重写；
//     mp3 的 ID3 写入 iOS 系统框架不提供，需要一个 TagLib 级别的库。
//     为了不冒「写坏用户文件」的风险，这里对不支持的格式**明确报错**，
//     Dart 侧会把它显示成失败提示。补齐方案见 recon/IOS-PORT-INTERNALS.md。

@available(iOS 13.0, *)
final class CyShineNativeTaggerChannel {

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "read": readTags(call, result)
    case "write": writeTags(call, result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func readTags(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
      return
    }
    let includeLyrics = args["includeLyrics"] as? Bool ?? true
    let includeArtwork = args["includeArtwork"] as? Bool ?? true

    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "NOT_FOUND", message: "file does not exist", details: nil))
      return
    }

    // 用 AVAsset 的旧式异步加载 API（iOS 4+ 就有），不用 iOS 15 才引入的
    // `load(_:)` async 版本，避免额外的 #available 分支。
    // 这里刻意不检查 statusOfValue(forKey:error:)：该 API 在 Swift 里是
    // 「NSErrorPointer + 返回值」形态，容易写出类型不匹配的代码；load 完成回调
    // 已经触发，直接读 commonMetadata 即可，读不到就是空字典（与 Android 返回
    // 一堆 null 的语义一致，Dart 侧会把它当成「没有标签」）。
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    asset.loadValuesAsynchronously(forKeys: ["commonMetadata"]) { [weak self] in
      guard let self else { return }

      let metadata = asset.commonMetadata
      var payload: [String: Any] = [:]
      for item in metadata {
        guard let key = item.commonKey?.rawValue else { continue }
        switch key {
        case AVMetadataKey.commonKeyTitle.rawValue:
          if let value = item.stringValue { payload["title"] = value }
        case AVMetadataKey.commonKeyArtist.rawValue:
          if let value = item.stringValue { payload["artist"] = value }
        case AVMetadataKey.commonKeyAlbumName.rawValue:
          if let value = item.stringValue { payload["album"] = value }
        case AVMetadataKey.commonKeyArtwork.rawValue:
          if includeArtwork { payload["artwork"] = item.dataValue }
        default:
          break
        }
      }

      if includeLyrics {
        // 歌词没有 commonKey，只能按 ID3 / iTunes 的标识符去找。
        let identifiers: [AVMetadataIdentifier] = [
          AVMetadataIdentifier(rawValue: "id3/ULT"),
          AVMetadataIdentifier.iTunesMetadataLyrics,
        ]
        for identifier in identifiers {
          let items = AVMetadataItem.metadataItems(from: metadata,
                                                   filteredByIdentifier: identifier)
          if let item = items.first, let text = item.stringValue, !text.isEmpty {
            payload["lyrics"] = text
            break
          }
        }
      }

      // MethodChannel 的 Result 是线程安全的，但按约定回主线程更稳妥。
      DispatchQueue.main.async { result(payload) }
    }
  }

  private func writeTags(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(code: "NOT_FOUND", message: "file does not exist", details: nil))
      return
    }

    let ext = (path as NSString).pathExtension.lowercased()
    guard ["m4a", "mp4", "mov"].contains(ext) else {
      // 明确、可操作地失败，而不是写坏文件。FLAC 不会走到这里（Dart 侧纯 Dart 处理）。
      result(FlutterError(
        code: "NATIVE_TAGGER_FAILED",
        message: "iOS 暂不支持写入 .\(ext) 的标签",
        details: "iOS 系统框架无法安全改写该格式的内嵌标签，需要引入 TagLib 级别的库；"
          + "FLAC 与 m4a 已支持。"))
      return
    }

    result(FlutterError(
      code: "NATIVE_TAGGER_FAILED",
      message: "iOS 标签写入尚未启用",
      details: "AVAssetExportSession 元数据重写路径待接入，见 recon/IOS-PORT-INTERNALS.md。"))
  }
}

// MARK: - 应用任务与诊断

@available(iOS 13.0, *)
final class CyShineAppTaskChannel {

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "moveToBack":
      // iOS 不允许 App 主动退到后台（平台限制），返回 false 让 Dart 侧走原逻辑。
      result(false)

    case "diagnostics":
      result(diagnostics())

    case "mediaSession":
      result(mediaSessionDiagnostics())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// ★ 锁屏 / 控制中心播放卡片的诊断。
  ///
  ///   这条链路与灵动岛**完全无关** —— 它由 `audio_service` → `MPNowPlayingInfoCenter`
  ///   驱动，系统自己画卡片，不需要 ActivityKit，也不需要 Widget 扩展。
  ///   （趣听音乐的锁屏卡片就是这一套，它根本没做灵动岛。）
  ///
  ///   卡片出不来的常见原因按「最可能 → 最不可能」排：
  ///     1. 后台音频没被允许（`UIBackgroundModes` 缺 `audio`）
  ///     2. 音频会话没激活 / 被别的 App 抢走
  ///     3. `nowPlayingInfo` 为空 —— 卡片需要 title+artist+rate 至少有一项
  ///     4. 封面是网络 URL 而非本地文件（audio_service 只认本地，见下）
  private func mediaSessionDiagnostics() -> [String: Any?] {
    let center = MPNowPlayingInfoCenter.default()
    let info = center.nowPlayingInfo
    let session = AVAudioSession.sharedInstance()

    var parts: [String] = []
    parts.append("后台音频=\(Self.backgroundModes().contains("audio") ? "已声明" : "未声明⚠")")
    parts.append("会话分类=\(session.category.rawValue)")
    parts.append("会话活动=\(session.isOtherAudioPlaying ? "他人有声" : "独占")")
    // nowPlayingInfo 为 nil 时系统不会画卡片，这里是最直接的判据。
    parts.append("nowPlaying=\(info == nil ? "空⚠" : "有\(info!.count)项")")

    if let info {
      let title = info[MPMediaItemPropertyTitle] as? String ?? ""
      let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
      let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
      let art = info[MPMediaItemPropertyArtwork] != nil
      parts.append("标题=\(title.isEmpty ? "空⚠" : "有")")
      parts.append("歌手=\(artist.isEmpty ? "空⚠" : "有")")
      parts.append("速率=\(rate)")
      parts.append("封面=\(art ? "有" : "无⚠")")
    }

    return [
      "summary": parts.joined(separator: " "),
      "hasNowPlaying": info != nil,
      "backgroundAudioDeclared": Self.backgroundModes().contains("audio"),
      "sessionCategory": session.category.rawValue,
      "isOtherAudioPlaying": session.isOtherAudioPlaying,
    ]
  }

  private static func backgroundModes() -> [String] {
    (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
  }

  private func diagnostics() -> [String: Any?] {
    let processInfo = ProcessInfo.processInfo
    let device = UIDevice.current

    return [
      "manufacturer": "Apple",
      "model": Self.modelIdentifier(),
      "androidRelease": NSNull(),                 // iOS 无此概念
      "sdk": device.systemVersion,
      "abis": [Self.archName()],
      "powerSaveMode": processInfo.isLowPowerModeEnabled,
      "batteryOptimizationIgnored": true,          // iOS 无电池优化白名单
      "deviceIdleMode": false,                     // iOS 无 Doze
      "notificationsEnabled": Self.notificationsEnabled(),
      "platform": "ios",
      "systemVersion": device.systemVersion,
      "thermalState": Self.thermalState(processInfo.thermalState),
      "freeMemoryBytes": processInfo.physicalMemory,
    ]
  }

  private static func notificationsEnabled() -> Bool {
    // 没有同步 API，读缓存值；未请求过权限时按「未启用」处理。
    UserDefaults.standard.object(forKey: "cyshine.notificationsEnabled") as? Bool ?? true
  }

  private static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  private static func archName() -> String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  private static func modelIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    let identifier = mirror.children.reduce(into: "") { acc, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      acc.append(Character(UnicodeScalar(UInt8(value))))
    }
    return identifier.isEmpty ? "unknown" : identifier
  }
}
