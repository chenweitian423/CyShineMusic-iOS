// CyShineMusic 实时活动（灵动岛）/ 桌面小组件 —— 主 App 侧桥接。
//
// 与 Dart 的契约（通道 `cy_shine_music/live_activity`）：
//   Dart → 原生：
//     isSupported   -> bool
//     start         {trackId,title,artist,cover,headers,durationMs,positionMs,playing}
//     update        {trackId,title,artist,cover,durationMs,positionMs,playing}
//     end           -> void
//     写入 App Group 给桌面小组件用的同一份数据（可选，容器不可用时静默跳过）
//   原生 → Dart：
//     control       "toggle" | "previous" | "next"   ← 灵动岛/锁屏卡片上的按钮
//     openPlayer                                     ← 点卡片主体
//
// 关于封面：Dart 给的是 `file://` 路径（audio_service 缓存好的内嵌封面）
// 或 http(s) 地址 + 请求头。这里把它解码、缩到 ≤256px、写成 JPEG 放进
// App Group 容器，再把相对路径放进 ContentState。**容器不可用时照常工作**，
// 只是灵动岛会显示扩展内置的音符占位图。
//
// 编译目标：Runner（主 App）。依赖同目录源码
// ios/CyShineMusicWidget/CyShineActivityAttributes.swift，
// 该文件由 tool/patch_xcodeproj.py 一并加进 Runner 的 Compile Sources。

import ActivityKit
import Flutter
import Foundation
import UIKit
import UserNotifications

@available(iOS 16.2, *)
final class CyShineLiveActivityBridge: NSObject {

  static let channelName = "cy_shine_music/live_activity"
  static let urlScheme = "cyshinemusic"

  /// 与 MusicHomeWidgetPlugin / Widget 扩展里保持一致。
  static let appGroupIdentifier = "group.com.cyshine.music"

  private static let artworkDirectory = "artwork"
  private static let maxArtworkPixels: CGFloat = 256

  private var channel: FlutterMethodChannel?
  private var activity: Activity<CyShineActivityAttributes>?

  /// 进入前台前发起活动会被系统拒绝（ActivityKit 要求前台）。
  /// 这里把待发起的状态留住，回到前台时补发。
  private var pendingStart: [String: Any]?
  private var foregroundObserver: NSObjectProtocol?

  // MARK: - 注册

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = CyShineLiveActivityBridge()
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    instance.channel = channel
    channel.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    // 进程启动时清掉上次残留的活动（避免灵动岛上挂着一条已经过期的）
    instance.endOrphanedActivities()
    instance.observeForeground()
    // 先把通知授权状态查一遍存起来，诊断里就能直接看到"通知=?"
    Self.refreshNotificationStatus()
    // 保持存活：通道回调是 weak 的，所以这里让 AppDelegate 侧持有
    shared = instance
  }

  /// 由 AppDelegate 持有，保证回调期间实例不被释放。
  private(set) static var shared: CyShineLiveActivityBridge?

  private func observeForeground() {
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, let pending = self.pendingStart else { return }
      self.pendingStart = nil
      _ = self.performStart(pending)
    }
  }

  // MARK: - 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      // 顺手把一次性的诊断信息打到 App 内「日志」页。
      // 灵动岛不出现时，用户只要截一张日志就能判断是「开关关了」还是
      // 「扩展根本没打进包」还是「系统拒绝了发起」，不用来回猜。
      CyShineNativeLog.write("live-activity", Self.diagnostics())
      result(ActivityAuthorizationInfo().areActivitiesEnabled)

    case "start":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少参数", details: nil))
        return
      }
      if ActivityAuthorizationInfo().areActivitiesEnabled == false {
        // 用户在「设置 → 栖弦 → 实时活动」里关掉了；不是错误，只是不支持。
        result(false)
        return
      }
      // 实时活动的显示依赖通知授权，而上游是纯 Android 项目、从没问过这个权限。
      // 在首次发起活动（= 首次播放）时问一次，别在冷启动就弹窗打扰。
      Self.ensureNotificationAuthorization()
      if UIApplication.shared.applicationState == .active {
        applyStart(args, result: result)
      } else {
        pendingStart = args
        CyShineNativeLog.write("live-activity",
                               "App 不在前台，已暂存发起，回到前台再补")
        result(true)
      }

    case "update":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少参数", details: nil))
        return
      }
      applyUpdate(args)
      result(true)

    case "end":
      endActivity(policy: .immediate)
      pendingStart = nil
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 最近一次查到的通知授权状态。`getNotificationSettings` 是异步的，
  /// 而诊断常常在同步路径上被读，所以这里缓存一份，不阻塞主线程。
  private static var notificationStatus = "未查询"
  private static var didRequestNotificationAuthorization = false

  /// 灵动岛是 iPhone 14 Pro 及以上的硬件。刘海屏机型（含 14/15/16 非 Pro）
  /// 的实时活动只出现在锁屏与通知中心 —— 这不是 bug，是硬件差异。
  /// 新机型没收录时按「支持」处理，避免误判成不支持。
  private static let dynamicIslandModels: Set<String> = [
    "iPhone15,2", "iPhone15,3",    // iPhone 14 Pro / Pro Max
    "iPhone16,1", "iPhone16,2",    // iPhone 15 Pro / Pro Max
    "iPhone17,1", "iPhone17,2",    // iPhone 16 Pro / Pro Max
    "iPhone18,1", "iPhone18,2",    // iPhone 17 Pro / Pro Max（预留）
  ]

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

  private static func deviceDescription() -> String {
    let model = modelIdentifier()
    guard model.hasPrefix("iPhone") else {
      // iPad 没有灵动岛，实时活动只出现在锁屏。
      return "\(model)(非 iPhone，无灵动岛)"
    }
    if dynamicIslandModels.contains(model) {
      return "\(model)(灵动岛机型)"
    }
    // 型号没收录时按支持处理，只提示一声，不误判。
    return "\(model)(未收录型号)"
  }

  /// 刷新缓存的通知授权状态。只写缓存、不弹窗、不阻塞。
  private static func refreshNotificationStatus() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      Self.notificationStatus = Self.describe(settings.authorizationStatus)
    }
  }

  private static func describe(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "已授权"
    case .denied: return "被拒绝（实时活动不会显示，去设置里打开）"
    case .notDetermined: return "未询问"
    case .provisional: return "临时授权"
    case .ephemeral: return "临时(App Clip)"
    @unknown default: return "未知"
    }
  }

  /// ★ 实时活动要显示，App 必须有通知授权（iOS 17 起「实时活动」开关就挂在
  ///   App 的通知设置里）。上游是纯 Android 项目，从来没有请求过这个权限，
  ///   侧载后授权状态一直是 notDetermined —— 这是「灵动岛怎么都不出现」的
  ///   高概率根因。放在首次发起活动（= 首次播放）时问一次，不打扰冷启动。
  static func ensureNotificationAuthorization() {
    guard didRequestNotificationAuthorization == false else { return }
    didRequestNotificationAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, error in
      Self.notificationStatus = granted ? "已授权" : "被拒绝"
      CyShineNativeLog.write(
        "live-activity",
        "通知授权结果 granted=\(granted) error=\(error?.localizedDescription ?? "无")"
      )
      Self.refreshNotificationStatus()
    }
  }

  /// 一次性的环境诊断。用来区分「没打进包」和「打进包但系统不给显示」。
  static func diagnostics() -> String {
    var parts: [String] = []
    parts.append("iOS \(UIDevice.current.systemVersion)")
    parts.append("机型=\(deviceDescription())")
    parts.append("开关=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
    parts.append("通知=\(notificationStatus)")
    parts.append("在跑的活动=\(Activity<CyShineActivityAttributes>.activities.count)")

    // 扩展是否真的躺在包里 —— 侧载工具重签时把 PlugIns 丢了的话，这里会是缺失。
    let plugIns = Bundle.main.builtInPlugInsURL
    let appex = plugIns?.appendingPathComponent("CyShineMusicWidget.appex")
    let executable = appex?.appendingPathComponent("CyShineMusicWidget")
    var hasBundle = false
    var appexIdentifier = "?"
    if let appex, let executable {
      hasBundle = FileManager.default.fileExists(atPath: appex.path)
      let hasBinary = FileManager.default.fileExists(atPath: executable.path)
      parts.append("扩展=\(hasBundle ? "在" : "缺失")/\(hasBinary ? "二进制在" : "二进制缺失")")
      appexIdentifier = Bundle(url: appex)?.bundleIdentifier ?? "?"
    } else {
      parts.append("扩展=无法定位 PlugIns")
    }

    // ★ 侧载重签时最容易踩的一条：工具只把主 App 的 bundle id 换成自己的，
    //   扩展的 id 没跟着改 → 前缀不匹配 → iOS 直接拒绝加载扩展，
    //   表现为「灵动岛不显示 + 桌面搜不到小组件」，而主 App 一切正常。
    let appIdentifier = Bundle.main.bundleIdentifier ?? "?"
    let prefixMatched = appexIdentifier.hasPrefix("\(appIdentifier).")
    let bundleNote = (hasBundle && !prefixMatched) ? " ⚠前缀不匹配，扩展会被拒绝加载" : ""
    parts.append("Bundle=\(appIdentifier)/\(appexIdentifier)\(bundleNote)")

    let group = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier)
    parts.append("AppGroup=\(group == nil ? "不可用（封面回退占位图）" : "可用")")
    return parts.joined(separator: " ")
  }

  /// 由 AppDelegate / SceneDelegate 在收到 `cyshinemusic://…` 时调用。
  /// 返回 true 表示这个 URL 由本桥接消费掉了。
  @discardableResult
  func handleIncomingURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == Self.urlScheme else { return false }
    let host = url.host?.lowercased() ?? ""
    let action: String?
    switch (host, url.lastPathComponent.lowercased()) {
    case (_, "toggle"), ("player", "toggle"): action = "toggle"
    case (_, "previous"), ("player", "previous"): action = "previous"
    case (_, "next"), ("player", "next"): action = "next"
    default: action = nil
    }
    if let action {
      // 只在真的带动作时才派发；单纯打开播放器交给路由处理。
      channel?.invokeMethod("control", arguments: action)
    } else {
      channel?.invokeMethod("openPlayer", arguments: nil)
    }
    return true
  }

  // MARK: - 活动生命周期

  private func endOrphanedActivities() {
    Task { @MainActor in
      for stale in Activity<CyShineActivityAttributes>.activities {
        await stale.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  private func applyStart(_ args: [String: Any], result: @escaping FlutterResult) {
    if let error = performStart(args) {
      result(FlutterError(code: "LIVE_ACTIVITY_FAILED",
                          message: "实时活动发起失败",
                          details: "\(Self.describe(error)) | \(Self.diagnostics())"))
    } else {
      result(true)
    }
  }

  /// 真正发起活动。返回 nil 表示成功。
  private func performStart(_ args: [String: Any]) -> Error? {
    guard let trackId = args["trackId"] as? String, !trackId.isEmpty else {
      return NSError(domain: "CyShineLiveActivity", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "缺少 trackId"])
    }

    // 同一首歌重复 start 时退化成 update，避免灵动岛上出现两条。
    if let current = activity, current.attributes.trackId == trackId {
      applyUpdate(args)
      return nil
    }
    endActivity(policy: .immediate)

    let payload = Self.payload(from: args)
    let attributes = CyShineActivityAttributes(trackId: trackId)
    do {
      activity = try Activity.request(
        attributes: attributes,
        content: ActivityContent(state: payload, staleDate: nil),
        pushType: nil
      )
    } catch {
      NSLog("[live-activity] 启动失败: \(error.localizedDescription)")
      CyShineNativeLog.write("live-activity", "发起失败: \(Self.describe(error)) | \(Self.diagnostics())")
      activity = nil
      // 桌面小组件不依赖 ActivityKit，失败也要把数据写进去。
      writeSharedState(args: args, artworkPath: nil)
      resolveArtworkForCurrent(args)
      return error
    }
    CyShineNativeLog.write("live-activity",
                           "活动已发起 id=\(activity?.id ?? "?") title=\(payload.title)")
    writeSharedState(args: args, artworkPath: nil)
    resolveArtworkForCurrent(args)
    return nil
  }

  static func describe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain)#\(ns.code) \(ns.localizedDescription)"
  }

  private func applyUpdate(_ args: [String: Any]) {
    guard let activity else {
      // 活动已经不在（用户划掉了 / 系统回收了）—— 当作一次新的发起。
      _ = performStart(args)
      return
    }
    // 换歌了就走 start 的路径（会重建活动）
    if let trackId = args["trackId"] as? String,
       !trackId.isEmpty,
       trackId != activity.attributes.trackId {
      _ = performStart(args)
      return
    }
    let payload = Self.payload(from: args)
    let content = ActivityContent(state: payload, staleDate: nil)
    Task { @MainActor in
      await activity.update(content)
    }
    writeSharedState(args: args, artworkPath: payload.artworkPath)
  }
  private func endActivity(policy: ActivityUIDismissalPolicy) {
    guard let activity else { return }
    self.activity = nil
    Task { @MainActor in
      await activity.end(nil, dismissalPolicy: policy)
    }
  }

  // MARK: - 封面

  /// 先不阻塞地发起活动，再把封面异步补上（写进 App Group 后 update 一次）。
  private func resolveArtworkForCurrent(_ args: [String: Any]) {
    guard let trackId = args["trackId"] as? String, !trackId.isEmpty else { return }
    let cover = (args["cover"] as? String) ?? ""
    let headers = (args["headers"] as? [String: Any])?
      .reduce(into: [String: String]()) { acc, e in acc[e.key] = String(describing: e.value) } ?? [:]

    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      guard let relative = Self.storeArtwork(trackId: trackId, cover: cover, headers: headers) else {
        return
      }
      await MainActor.run {
        guard let activity = self.activity,
              activity.attributes.trackId == trackId else { return }
        var state = Self.lastState ?? Self.emptyState()
        state.artworkPath = relative
        Self.lastState = state
        Task { @MainActor in
          await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        self.writeSharedState(args: args, artworkPath: relative)
      }
    }
  }

  /// 把封面落到 App Group 容器，返回相对路径。
  /// 容器不可用（没开 App Groups 能力）时返回 nil —— 调用方会让 UI 回退到占位图。
  private static func storeArtwork(
    trackId: String,
    cover: String,
    headers: [String: String]
  ) -> String? {
    guard let base = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }

    let data: Data?
    if cover.hasPrefix("file://"), let url = URL(string: cover) {
      data = try? Data(contentsOf: url)
    } else if let url = URL(string: cover), url.scheme?.hasPrefix("http") == true {
      data = downloadSynchronously(url: url, headers: headers)
    } else if !cover.isEmpty {
      data = try? Data(contentsOf: URL(fileURLWithPath: cover))
    } else {
      data = nil
    }
    guard let data, let image = UIImage(data: data) else { return nil }
    guard let scaled = downscale(image, maxPixels: maxArtworkPixels),
          let jpeg = scaled.jpegData(compressionQuality: 0.82) else { return nil }

    let directory = base.appendingPathComponent(artworkDirectory, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let safeName = trackId.replacingOccurrences(
      of: "[^A-Za-z0-9_-]",
      with: "_",
      options: .regularExpression
    )
    // 固定用 current.jpg：避免每换一首歌就在容器里堆一个文件。
    let file = directory.appendingPathComponent("current.jpg")
    // 记录来源曲目，供小组件判断封面是否对应当前歌曲
    UserDefaults(suiteName: appGroupIdentifier)?
      .set(safeName, forKey: "widget.artworkTrackId")
    guard (try? jpeg.write(to: file, options: .atomic)) != nil else { return nil }
    return "\(artworkDirectory)/current.jpg"
  }

  private static func downloadSynchronously(
    url: URL,
    headers: [String: String]
  ) -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let semaphore = DispatchSemaphore(value: 0)
    var output: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
      output = data
      semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 15)
    return output
  }

  private static func downscale(_ image: UIImage, maxPixels: CGFloat) -> UIImage? {
    let side = max(image.size.width, image.size.height)
    guard side > 0 else { return nil }
    let scale = min(1, maxPixels / side)
    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
  }

  // MARK: - 给桌面小组件用的共享数据

  private func writeSharedState(args: [String: Any], artworkPath: String?) {
    guard let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) else { return }
    defaults.set((args["trackId"] as? String) ?? "", forKey: "widget.trackId")
    defaults.set((args["title"] as? String) ?? "", forKey: "widget.title")
    defaults.set((args["artist"] as? String) ?? "", forKey: "widget.artist")
    defaults.set((args["playing"] as? Bool) ?? false, forKey: "widget.playing")
    defaults.set(artworkPath ?? "", forKey: "widget.artworkFile")
    defaults.set(Date().timeIntervalSince1970, forKey: "widget.updatedAt")
  }

  // MARK: - ContentState 构造

  /// 最近一次的 state。封面是异步补上的，需要一个地方暂存它。
  private static var lastState: CyShineActivityAttributes.ContentState?

  private static func emptyState() -> CyShineActivityAttributes.ContentState {
    .init(title: "", artist: "", positionMs: 0, durationMs: 0,
          playing: false, updatedAt: Date().timeIntervalSince1970, artworkPath: nil)
  }

  private static func payload(
    from args: [String: Any]
  ) -> CyShineActivityAttributes.ContentState {
    let durationMs = (args["durationMs"] as? NSNumber)?.intValue ?? 0
    let title = (args["title"] as? String) ?? ""
    let artist = (args["artist"] as? String) ?? ""
    var state = CyShineActivityAttributes.ContentState(
      title: title,
      artist: artist,
      positionMs: (args["positionMs"] as? NSNumber)?.intValue ?? 0,
      durationMs: durationMs,
      playing: (args["playing"] as? Bool) ?? false,
      updatedAt: Date().timeIntervalSince1970,
      // 同一首歌的后续更新沿用已经写好的封面路径
      artworkPath: lastState?.artworkPath
    )
    // 换歌时把上一首的封面路径丢掉，避免新歌短暂显示旧封面
    if let previous = lastState, previous.title != title, !previous.title.isEmpty {
      state.artworkPath = nil
    }
    lastState = state
    return state
  }
}
