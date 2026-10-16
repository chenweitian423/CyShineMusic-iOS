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

@available(iOS 16.1, *)
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
      self.applyStart(pending)
    }
  }

  // MARK: - 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
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
      if UIApplication.shared.applicationState == .active {
        applyStart(args)
      } else {
        pendingStart = args
      }
      result(true)

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

  private func applyStart(_ args: [String: Any]) {
    guard let trackId = args["trackId"] as? String, !trackId.isEmpty else { return }

    // 同一首歌重复 start 时退化成 update，避免灵动岛上出现两条。
    if let current = activity, current.attributes.trackId == trackId {
      applyUpdate(args)
      return
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
      // 常见原因：App 不在前台、系统关闭了实时活动、或超过活动数量上限。
      // 记一条日志，不抛给 Dart —— 实时活动失败不该影响播放。
      NSLog("[live-activity] 启动失败: \(error.localizedDescription)")
      activity = nil
      writeSharedState(args: args, artworkPath: nil)
      resolveArtworkForCurrent(args)
      return
    }
    writeSharedState(args: args, artworkPath: nil)
    resolveArtworkForCurrent(args)
  }

  private func applyUpdate(_ args: [String: Any]) {
    guard let activity else { return }
    // 换歌了就走 start 的路径（会重建活动）
    if let trackId = args["trackId"] as? String,
       !trackId.isEmpty,
       trackId != activity.attributes.trackId {
      applyStart(args)
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
