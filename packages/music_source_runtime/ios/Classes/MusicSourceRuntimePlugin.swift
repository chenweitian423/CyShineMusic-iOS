// CyShineMusic iOS —— 自定义音源运行时。
//
// 与 Android 的 packages/music_source_runtime 保持完全相同的契约：
//
//   MethodChannel  cy_shine_music/music_source_runtime
//   MethodChannel  cy_shine_music/music_source_update_runtime
//     load      {id,name,description,author,homepage,version,sourceKey,script} -> {sources:{...}}
//     resolve   {source,quality,musicInfo} -> {url,fileName?}
//     dispose   -> void
//     httpResponse {requestId,response?,error?} -> void
//
//   回调 Dart（channel.invokeMethod('event', ...)）：
//     {type:'httpRequest', requestId, ownerRequestId?, url, options}
//     {type:'httpCancel', requestId}
//     {type:'updateAlert', ...}
//     {type:'log', level, message}
//
//   发给 JS 的入口（由 assets 里的 music_source_preload.js 定义）：
//     globalThis.music_source_setup(metadataJson)
//     globalThis.__music_source_handle__(action, dataJson)
//
// 关键点：脚本用到的 8 个 native 函数必须全部提供，否则 preload.js 里的
// music_source_setup 会拿不到引用而直接抛错。清单见 registerNativeFunctions()。
//
// JS 引擎选型说明：这里用系统自带的 JavaScriptCore（iOS 内置、零依赖、可离线构建）。
// Android 用的 QuickJS 与 JSCore 在脚本语义上一致（preload.js 只依赖标准
// ES2017+ 与自身注入的 native 函数），因此脚本行为保持对齐。若日后遇到某个
// 音源在 JSCore 下行为异常，可以只替换 SourceScriptSession 里创建 JSContext 的
// 部分（把 engine 抽象成协议）而不动其余通道逻辑。

import Flutter
import Foundation
import JavaScriptCore

public final class MusicSourceRuntimePlugin: NSObject, FlutterPlugin {

  static let runtimeChannelName = "cy_shine_music/music_source_runtime"
  static let updateChannelName = "cy_shine_music/music_source_update_runtime"

  private var sessions: [SourceScriptSession] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = MusicSourceRuntimePlugin()
    instance.attach(registrar: registrar)
    registrar.publish(instance)
  }

  private func attach(registrar: FlutterPluginRegistrar) {
    // 两个通道各自持有独立的 JS 运行时，与 Android 的两次
    // MusicSourceRuntimeBridge 实例化一一对应，互不串扰。
    for name in [Self.runtimeChannelName, Self.updateChannelName] {
      let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
      let session = SourceScriptSession(channel: channel)
      channel.setMethodCallHandler { [weak session] call, result in
        session?.handle(call, result: result)
      }
      sessions.append(session)
    }
  }
}

// MARK: - 单个通道对应的 JS 会话

final class SourceScriptSession: NSObject {

  private let channel: FlutterMethodChannel
  /// 所有 JS 访问都串行化在这条队列上；JSCore 的 JSContext 不是线程安全的。
  private let jsQueue = DispatchQueue(label: "com.cyshine.music.source.js")
  private let timerQueue = DispatchQueue(label: "com.cyshine.music.source.timer")

  private var context: JSContext?
  private var metadata: [String: String] = [:]
  private var timers: [Int: DispatchWorkItem] = [:]

  private var loadCompletion: ((Result<[String: Any?], Error>) -> Void)?
  private var resolveCompletion: ((Result<[String: Any?], Error>) -> Void)?
  private var disposed = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  // MARK: 通道入口

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "load":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少参数", details: nil))
        return
      }
      let script = args["script"] as? String ?? ""
      var info: [String: String] = [:]
      for key in ["id", "name", "description", "author", "homepage", "version", "sourceKey"] {
        info[key] = (args[key] as? String) ?? ""
      }
      metadata = info
      startLoad(script: script, metadata: info, result: result)

    case "resolve":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "INVALID_ARGS", message: "缺少参数", details: nil))
        return
      }
      startResolve(args: args, result: result)

    case "dispose":
      disposeRuntime()
      result(nil)

    case "httpResponse":
      let args = call.arguments as? [String: Any] ?? [:]
      deliverHttpResponse(args)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: load

  private func startLoad(script: String,
                         metadata: [String: String],
                         result: @escaping FlutterResult) {
    jsQueue.async {
      self.teardown()
      // teardown() 会把 disposed 置为 true；重新 load 时必须复位，
      // 否则后续 resolve 会被误判成「运行时已释放」。
      self.disposed = false
      self.loadCompletion = { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let value): result(value)
          case .failure(let error):
            result(FlutterError(code: "MUSIC_SOURCE_RUNTIME",
                                message: (error as? SourceRuntimeError)?.message ?? "\(error)",
                                details: nil))
          }
        }
      }

      do {
        let context = try self.makeContext()
        self.context = context

        // 先跑 preload，再跑音源脚本，最后把 metadata 交给 preload 完成装配。
        let preload = Self.preloadScript()
        if preload.isEmpty {
          throw SourceRuntimeError("找不到内置脚本 music_source_preload.js")
        }
        try self.evaluateScript(preload, in: context)
        try self.evaluateScript(script, in: context)

        let metadataJson = Self.encodeJSON(metadata)
        guard let setup = context.objectForKeyedSubscript("music_source_setup"),
              !setup.isUndefined else {
          throw SourceRuntimeError("音源运行时未提供 music_source_setup")
        }
        setup.call(withArguments: [metadataJson])
        try self.throwIfPendingException(context, fallback: "音源初始化失败")

        // 正常情况下脚本会调 lx.send('inited', ...) -> native_call('init', ...)
        // 来兑现这个 Future；同步就完成的（或根本没发 inited 的）由超时兜底。
        self.scheduleLoadTimeout()
      } catch {
        let completion = self.loadCompletion
        self.loadCompletion = nil
        completion?(.failure(error))
      }
    }
  }

  private func scheduleLoadTimeout() {
    timerQueue.asyncAfter(deadline: .now() + 12) { [weak self] in
      guard let self else { return }
      self.jsQueue.async {
        guard let completion = self.loadCompletion else { return }
        self.loadCompletion = nil
        completion(.failure(SourceRuntimeError("音源初始化超时")))
      }
    }
  }

  // MARK: resolve

  private func startResolve(args: [String: Any], result: @escaping FlutterResult) {
    jsQueue.async {
      guard let context = self.context, !self.disposed else {
        DispatchQueue.main.async {
          result(FlutterError(code: "MUSIC_SOURCE_RUNTIME",
                              message: "音源尚未初始化", details: nil))
        }
        return
      }
      if self.resolveCompletion != nil {
        DispatchQueue.main.async {
          result(FlutterError(code: "MUSIC_SOURCE_RUNTIME",
                              message: "已有解析正在进行", details: nil))
        }
        return
      }

      self.resolveCompletion = { outcome in
        DispatchQueue.main.async {
          switch outcome {
          case .success(let value): result(value)
          case .failure(let error):
            result(FlutterError(code: "MUSIC_SOURCE_RUNTIME",
                                message: (error as? SourceRuntimeError)?.message ?? "\(error)",
                                details: nil))
          }
        }
      }

      // requestId 由原生侧生成，preload.js 会原样带回来。
      let requestId = String(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000)
      var payload: [String: Any] = [
        "requestId": requestId,
        "source": args["source"] as? String ?? "",
        "quality": args["quality"] as? String ?? "",
        "musicInfo": args["musicInfo"] as? [String: Any] ?? [:],
      ]

      guard let handle = context.objectForKeyedSubscript("__music_source_handle__"),
            !handle.isUndefined else {
        let completion = self.resolveCompletion
        self.resolveCompletion = nil
        completion?(.failure(SourceRuntimeError("音源运行时未就绪")))
        return
      }
      handle.call(withArguments: ["resolve", Self.encodeJSON(payload)])
      // 正常情况下 preload.js 的 runResolve 会自己 try/catch 并回 resolveResult；
      // 这里只是兜底：真出现同步异常就直接判这次解析失败，避免 Dart 侧干等到超时。
      do {
        try self.throwIfPendingException(context, fallback: "音源解析失败")
      } catch {
        let completion = self.resolveCompletion
        self.resolveCompletion = nil
        completion?(.failure(error))
        return
      }

      self.scheduleResolveTimeout()
    }
  }

  private func scheduleResolveTimeout() {
    timerQueue.asyncAfter(deadline: .now() + 35) { [weak self] in
      guard let self else { return }
      self.jsQueue.async {
        guard let completion = self.resolveCompletion else { return }
        self.resolveCompletion = nil
        completion(.failure(SourceRuntimeError("音源解析超时")))
      }
    }
  }

  // MARK: httpResponse（Dart 侧完成网络请求后回灌）

  private func deliverHttpResponse(_ args: [String: Any]) {
    jsQueue.async {
      guard let context = self.context else { return }
      guard let handle = context.objectForKeyedSubscript("__music_source_handle__"),
            !handle.isUndefined else { return }
      handle.call(withArguments: ["httpResponse", Self.encodeJSON(args)])
      // 这里在非 throwing 的队列闭包里，用日志版兜底即可：
      // 脚本自己的 Promise 链会把结果走 resolveResult 回来。
      self.reportPendingException(context, fallback: "音源响应处理失败")
      // 脚本收到响应后可能同步走完 resolve 链，这里补一次微任务冲刷。
      self.drainMicrotasks(context)
    }
  }

  // MARK: 释放

  private func disposeRuntime() {
    jsQueue.async {
      self.teardown()
    }
  }

  private func teardown() {
    disposed = true
    for (_, work) in timers { work.cancel() }
    timers.removeAll()
    context = nil
    if let completion = loadCompletion {
      loadCompletion = nil
      completion(.failure(SourceRuntimeError("音源运行时已释放")))
    }
    if let completion = resolveCompletion {
      resolveCompletion = nil
      completion(.failure(SourceRuntimeError("音源运行时已释放")))
    }
  }

  // MARK: JS 环境

  private func makeContext() throws -> JSContext {
    guard let context = JSContext() else {
      throw SourceRuntimeError("无法创建 JS 运行时")
    }
    context.exceptionHandler = { [weak self] _, exception in
      let message = exception?.toString() ?? "unknown"
      self?.emitLog(level: "error", message: message)
    }
    registerNativeFunctions(on: context)
    registerConsole(on: context)
    return context
  }

  /// preload.js 里 music_source_setup 会一次性取走这 8 个函数，缺一不可。
  private func registerNativeFunctions(on context: JSContext) {
    func expose(_ name: String, _ block: AnyObject) {
      context.setObject(block, forKeyedSubscript: name as NSString)
    }

    // (action, payloadJson) -> void
    let nativeCall: @convention(block) (String, String) -> Void = { [weak self] action, json in
      self?.handleNativeAction(action: action, json: json)
    }
    expose("__music_source_native_call__", unsafeBitCast(nativeCall, to: AnyObject.self))

    let md5Block: @convention(block) (String) -> String = { value in
      Self.guardJS { try MusicSourceCrypto.md5(value) }
    }
    expose("__music_source_md5__", unsafeBitCast(md5Block, to: AnyObject.self))

    let bytesToB64: @convention(block) (String) -> String = { jsonBytes in
      Self.guardJS { try MusicSourceCrypto.bytesToBase64(jsonBytes) }
    }
    expose("__music_source_bytes_to_b64__", unsafeBitCast(bytesToB64, to: AnyObject.self))

    let b64ToBytes: @convention(block) (String) -> String = { value in
      Self.guardJS { try MusicSourceCrypto.base64ToBytes(value) }
    }
    expose("__music_source_b64_to_bytes__", unsafeBitCast(b64ToBytes, to: AnyObject.self))

    let aesEncrypt: @convention(block) (String, String, String, String) -> String = {
      data, key, iv, transformation in
      Self.guardJS {
        try MusicSourceCrypto.aesEncrypt(data, key, iv, transformation)
      }
    }
    expose("__music_source_aes_encrypt__", unsafeBitCast(aesEncrypt, to: AnyObject.self))

    let rsaEncrypt: @convention(block) (String, String, String) -> String = {
      data, key, padding in
      Self.guardJS {
        try MusicSourceCrypto.rsaEncrypt(data, key, padding)
      }
    }
    expose("__music_source_rsa_encrypt__", unsafeBitCast(rsaEncrypt, to: AnyObject.self))

    let setTimer: @convention(block) (Double, Double) -> Void = { [weak self] id, delayMs in
      self?.scheduleTimer(id: Int(id), delayMs: delayMs)
    }
    expose("__music_source_set_timeout__", unsafeBitCast(setTimer, to: AnyObject.self))

    let clearTimer: @convention(block) (Double) -> Void = { [weak self] id in
      self?.cancelTimer(id: Int(id))
    }
    expose("__music_source_clear_timeout__", unsafeBitCast(clearTimer, to: AnyObject.self))
  }

  private func registerConsole(on context: JSContext) {
    let jsConsole = JSValue(newObjectIn: context)
    for level in ["log", "info", "warn", "error", "debug"] {
      let block: @convention(block) (JSValue?) -> Void = { [weak self] value in
        let text: String
        if let value, !value.isUndefined {
          text = value.toString() ?? ""
        } else {
          text = ""
        }
        self?.emitLog(level: level, message: text)
      }
      jsConsole?.setObject(unsafeBitCast(block, to: AnyObject.self),
                           forKeyedSubscript: level as NSString)
    }
    context.setObject(jsConsole, forKeyedSubscript: "console" as NSString)
  }

  /// 把 Kotlin/Java 侧抛异常的行为映射成 JS 异常，脚本能照常 try/catch。
  private static func guardJS(_ body: () throws -> String) -> String {
    do {
      return try body()
    } catch {
      if let context = JSContext.current() {
        context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
      }
      return ""
    }
  }

  // MARK: native -> Dart -> JS 的动作分发

  private func handleNativeAction(action: String, json: String) {
    switch action {
    case "init":
      handleInit(json: json)

    case "resolveResult":
      handleResolveResult(json: json)

    case "httpRequest":
      guard let payload = Self.decodeJSON(json) else { return }
      emitEvent([
        "type": "httpRequest",
        "requestId": payload["requestId"] ?? "",
        "ownerRequestId": payload["ownerRequestId"] ?? NSNull(),
        "url": payload["url"] ?? "",
        "options": payload["options"] ?? [:],
      ])

    case "httpCancel":
      let payload = Self.decodeJSON(json)
      emitEvent(["type": "httpCancel", "requestId": payload?["requestId"] ?? ""])

    case "updateAlert":
      guard let payload = Self.decodeJSON(json) else { return }
      var event: [String: Any] = ["type": "updateAlert"]
      for (key, value) in payload { event[key] = value }
      emitEvent(event)

    case "log":
      let payload = Self.decodeJSON(json)
      emitLog(level: payload?["level"] as? String ?? "log",
              message: payload?["message"] as? String ?? "")

    default:
      break
    }
  }

  private func handleInit(json: String) {
    guard let payload = Self.decodeJSON(json) else { return }
    let completion = loadCompletion
    loadCompletion = nil

    if payload["status"] as? Bool == true {
      // Dart 侧只认 {sources: {...}}，preload 已经把能力归一化好了。
      // 注意 [String: Any] 不能隐式转成 [String: Any?]，要手工搬一次。
      let info = payload["info"] as? [String: Any] ?? [:]
      var mapped: [String: Any?] = [:]
      for (key, value) in info { mapped[key] = value }
      completion?(.success(mapped))
    } else {
      completion?(.failure(SourceRuntimeError(payload["error"] as? String ?? "音源初始化失败")))
    }
  }

  private func handleResolveResult(json: String) {
    guard let payload = Self.decodeJSON(json) else { return }
    let completion = resolveCompletion
    resolveCompletion = nil

    if payload["status"] as? Bool == true {
      var value: [String: Any?] = ["url": payload["url"] ?? ""]
      if let fileName = payload["fileName"] as? String, !fileName.isEmpty {
        value["fileName"] = fileName
      }
      completion?(.success(value))
    } else {
      completion?(.failure(SourceRuntimeError(payload["error"] as? String ?? "音源解析失败")))
    }
  }

  // MARK: 定时器

  private func scheduleTimer(id: Int, delayMs: Double) {
    cancelTimer(id: id)
    // 与 Android 一致：夹在 0...60s。
    let clamped = max(0, min(delayMs, 60_000)) / 1000.0
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.timers.removeValue(forKey: id)
      self.jsQueue.async { self.deliverTimeout(id: id) }
    }
    timers[id] = work
    timerQueue.asyncAfter(deadline: .now() + clamped, execute: work)
  }

  private func cancelTimer(id: Int) {
    if let work = timers.removeValue(forKey: id) { work.cancel() }
  }

  private func deliverTimeout(id: Int) {
    guard let context, !disposed else { return }
    guard let handle = context.objectForKeyedSubscript("__music_source_handle__"),
          !handle.isUndefined else { return }
    // preload.js 里是 Number(dataJson)，Android 传的也是字符串。
    handle.call(withArguments: ["timeout", String(id)])
    reportPendingException(context, fallback: "定时回调失败")
    drainMicrotasks(context)
  }

  /// 非 throwing 上下文（队列闭包、DSP/定时器回调）里用：
  /// 把 JS 异常转成一条 error 日志，不中断流程。
  private func reportPendingException(_ context: JSContext, fallback: String) {
    guard let exception = context.exception else { return }
    let message = exception.toString() ?? fallback
    context.exception = nil
    emitLog(level: "error", message: message)
  }

  // MARK: 工具

  private func evaluateScript(_ source: String, in context: JSContext) throws {
    context.evaluateScript(source)
    try throwIfPendingException(context, fallback: "脚本执行失败")
  }

  private func throwIfPendingException(_ context: JSContext, fallback: String) throws {
    guard let exception = context.exception else { return }
    let message = exception.toString() ?? fallback
    context.exception = nil
    throw SourceRuntimeError(message)
  }

  /// JSCore 会在 API 入口结束后冲刷微任务队列；这里显式跑一次 Promise 链的
  /// then 回调，保证 httpResponse 之后脚本能继续往下走。
  private func drainMicrotasks(_ context: JSContext) {
    context.evaluateScript("Promise.resolve();")
  }

  private func emitEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      self.channel.invokeMethod("event", arguments: payload)
    }
  }

  private func emitLog(level: String, message: String) {
    emitEvent(["type": "log", "level": level, "message": message])
  }

  private static func encodeJSON(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: []),
          let text = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return text
  }

  private static func decodeJSON(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
  }

  /// preload.js 与 Android 端共用同一份文件，由 CI 校验两处 md5 一致。
  ///
  /// 用 `s.resources` 引入时文件会被拷进 App 主 bundle；但若将来改成
  /// `s.resource_bundles`，就会落在独立 bundle 里。这里两种位置都找一遍，
  /// 找不到就返回空串，由调用方给出可读的中文报错。
  private static func preloadScript() -> String {
    let candidates: [Bundle] = [
      Bundle(for: SourceScriptSession.self),
      Bundle.main,
    ]
    for bundle in candidates {
      if let url = bundle.url(forResource: "music_source_preload", withExtension: "js"),
         let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
        return text
      }
    }
    return ""
  }
}

struct SourceRuntimeError: Error, CustomStringConvertible {
  let message: String

  init(_ message: String) { self.message = message }

  var description: String { message }
}
