# CyShineMusic iOS 移植 — 内部文档

> 不下发。交付说明（怎么装）在 `ios/README-IOS.md`；本文记录机制、契约、验收、踩坑与待办。
> 最后更新：2026-10-16

---

## 0. 一句话现状

上游 `KevinllBin/CyShineMusic`（MIT，纯 Android）到 iOS 的移植。**核心发现：`lib/` 的 Dart
业务层几乎可以原样复用**——作者已经把 Android-only 的东西都用 `Platform.isAndroid` 守卫起来了。
移植工作量 100% 集中在原生插件层：11 个 MethodChannel 全部 Android-only，其中 3 个是本地
path 插件（bass_player / music_source_runtime / music_home_widget），8 个注册在 Runner 的
MainActivity.kt 里。

因为**通道契约保持不变**，所以移植策略是「换原生实现，不动 Dart」，极大降低与上游 rebase 的冲突面。

**编译状态：已在 GitHub Actions（macos-latest）上完整跑通并产出未签名 IPA。**
远程仓库 `chenweitian423/CyShineMusic-iOS` 分支 `ios`，最新成功 run `38908158309`，
产物 `ios-v2.0.1 (build 17)`，15,769,066 B，md5 `8b1d9f65107c1ccb518bf9f62a8235df`。
已核实内嵌 `bass/bassflac/bassape/bassopus/basswv/bassdsd` 六个 BASS framework、
`bass_player/music_source_runtime/music_home_widget` 三个插件 framework、
`music_source_runtime.framework/music_source_preload.js`、
`PlugIns/CyShineMusicWidget.appex`（灵动岛 + 桌面小组件）、
`Info.plist`（`UIBackgroundModes=[audio,fetch]`、`CFBundleAlternateIcons` 5 项）。

**真机已装并跑起来（2026-10-16，iPhone 自签安装），播放链路已通。** 已修的真机 bug：

| # | 现象 | 根因 | 修复版本 |
|---|---|---|---|
| 1 | 导入音源报「音源初始化超时」 | 音源脚本执行顺序写反 + JSCore 异常被吞（见 #15/#16） | `v1.0.8-ios.2` |
| 2 | 搜歌播放报 `BASS playback is available on Android only` | Dart 插件层遗留平台守卫（见 #20） | `v1.0.8-ios.3` |
| 3 | 点状态栏不回顶 | 框架实现被外壳 Scaffold 挡住（见 #22） | `v1.0.8-ios.4` |
| 4 | 灵动岛不显示 | ★ 通知授权从未请求过（上游是纯 Android 项目，见 #40）；另加诊断判据待复测 | `ios-v2.0.1` |

**当前唯一卡点**：灵动岛待真机复测 `ios-v2.0.1`。排查入口是 App 内
「设置 → 日志」页的 `live-activity` 一行（见 6.4 节第 4 条的字段表）。

---

## 1. 上游基线

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/KevinllBin/CyShineMusic |
| 许可 | MIT，`Copyright (c) 2026 KevinllBin` |
| 分支 | `main`（`dev` 用不同包名可共存安装） |
| 基线提交 | `main` @ 2026-10-15（本地快照位于 `_upstream_CyShineMusic`） |
| 版本 | `cy_shine_music 1.0.8+9`，Dart `^3.11.4`，Flutter `>=3.41.0` |
| 语言构成 | Dart 2.66 MB / Java 137 KB / HTML 130 KB / Kotlin 82 KB / JS 10 KB / GLSL 4.9 KB |

本地工作副本：`CyShineMusic-iOS/`，已 `git init -b ios`，远端 `upstream` 指向官方仓库。

---

## 2. 通道契约对照表（移植的全部接口面）

### 2.1 `packages/bass_player`

| 通道 | 方法 | 参数 | 返回 |
|---|---|---|---|
| `com.cyshine.music/bass_player/methods` | initialize | — | `{version, fxVersion, plugins:{flac,ape,alac}}` |
| | load | `{uri, headers, formatHint}` | snapshot |
| | play / pause / stop | — | snapshot |
| | seek | `{positionMs}` | snapshot |
| | setVolume | `{volume}` | snapshot |
| | setEqualizer | `{enabled, inputGainDb, outputGainDb, bands:[{id,filter,frequencyHz,enabled,gainDb,q}]}` | snapshot |
| | dispose | — | `{}` |
| `com.cyshine.music/bass_player/events` | 事件流 | — | snapshot / error |

snapshot 字段（与 Android `snapshot()` 逐字对应）：
`{event:"snapshot", playing:bool, processingState:"idle|loading|buffering|ready|completed|error",
positionMs:int, bufferedPositionMs:int, durationMs:int|null}`

错误：`FlutterError(code:"BASS_<int>", message, details:{operation, bassCode})`。
⚠️ Dart 侧 `BassPlayerException.fromPlatform` 用正则 `^BASS_(-?\d+)$` 解析 code，
所以 **错误码格式不能改**。

`load` 的 header 注入方式（与 Android 完全一致）：把 `\r\nName: Value\r\n...\r\n`
**直接追加在 URL 字符串后面**，BASS 会当成 HTTP 请求头解析。

`formatHint` 归一化（`normalizedFormat`）：`flac/ape/alac/m4a/wv/opus/dsd/ogg` 原样；
`flac24bit|hires|master|lossless` → `lossless`；其它 → `generic`。为空的按扩展名推断。

### 2.2 `packages/music_source_runtime`

| 通道 | 方法 | 参数 | 返回 |
|---|---|---|---|
| `cy_shine_music/music_source_runtime` | load | `{id,name,description,author,homepage,version,sourceKey,script}` | `{sources:{code:{type,actions,qualitys}}}` |
| 同上 | resolve | `{source, quality, musicInfo}` | `{url, fileName?}` |
| 同上 | dispose | — | void |
| 同上 | httpResponse | `{requestId, response?, error?}` | void |
| `cy_shine_music/music_source_update_runtime` | 同上 | 同上 | 同上 |

原生 → Dart 的回调（`channel.invokeMethod('event', {...})`）：

| type | 载荷 | 说明 |
|---|---|---|
| `httpRequest` | `{requestId, ownerRequestId, url, options}` | **网络请求在 Dart 侧发**，原生不管 HTTP |
| `httpCancel` | `{requestId}` | |
| `updateAlert` | `{sourceId, sourceKey, log, updateUrl}` | |
| `log` | `{level, message}` | |

**关键：HTTP 完全在 Dart 侧实现**（`_handleHttpRequest` 用 dio 发），原生只做事件转发。
这大幅降低了 iOS 侧的实现量——不需要在原生里做网络栈。

### 2.3 `packages/music_home_widget`

| 通道 | 方法 | 参数 |
|---|---|---|
| `cy_shine_music/home_widget` | ready | — |
| | openApp | — |
| | update | `{trackId,title,artist,cover,headers}` |
| | updatePlayback | `{playing,loading}` |
| 原生 → Dart | `control` | `"toggle" | "previous" | "next"` |
| | `openPlayer` | — |

⚠️ Dart 侧有 `if (!Platform.isAndroid) return;`（`music_home_widget_service.dart:44`），
所以现在 iOS 主 App 不会调用。要让 iOS 小组件生效，需要把这个守卫放开。

### 2.4 Runner 侧 6 个通道（Android 实现在 `MainActivity.kt` / `AppIconManager.kt`）

| 通道 | 方法 | 参数 | 返回 |
|---|---|---|---|
| `cy_shine_music/app_icon` | getCurrentIcon | — | `"classic" | "midnight" | ...` |
| | setIcon | `{icon}` | 生效后的 code |
| `cy_shine_music/media_scan` | scan | `{path}` | bool |
| `cy_shine_music/storage_browser` | listRoots | — | `[entry]` |
| | listChildren | `{path, includeFiles}` | `[entry]` |
| `cy_shine_music/audio_intent` | takePendingAudio | — | path / null |
| | openAudio | `{path}` | bool |
| 原生 → Dart | `audioAvailable` | — | — |
| `cy_shine_music/native_tagger` | read | `{path, includeLyrics, includeArtwork}` | `{title,artist,album,lyrics,artwork:Uint8List?}` |
| | write | `{path,title,artist,album,lyrics,artwork,artworkMimeType}` | `{lyricsLength, artworkLength}` |
| `cy_shine_music/app_task` | moveToBack | — | bool |
| | diagnostics | — | `{manufacturer,model,androidRelease,sdk,abis,powerSaveMode,batteryOptimizationIgnored,deviceIdleMode,notificationsEnabled}` |

`storage_browser` 的 entry 字段：
`{path,name,isDirectory,isRoot,isRemovable,canRead,canWrite,totalBytes,freeBytes,state}`

---

## 3. JS 音源运行时契约（`music_source_preload.js`）

native 必须提供 **8 个**全局函数，缺一个 `music_source_setup` 就会抛错：

| 函数 | 签名 | 对应 Android 实现 |
|---|---|---|
| `__music_source_native_call__` | `(action:string, json:string) -> void` | `MusicSourceRuntimeBridge.handleScriptAction` |
| `__music_source_md5__` | `(string) -> hex` | `MusicSourceCrypto.md5` |
| `__music_source_bytes_to_b64__` | `(jsonArrayString) -> base64` | `.bytesToBase64` |
| `__music_source_b64_to_bytes__` | `(base64) -> jsonArrayString` | `.base64ToBytes` |
| `__music_source_aes_encrypt__` | `(dataB64,keyB64,ivB64,transformation) -> base64` | `.aesEncrypt` |
| `__music_source_rsa_encrypt__` | `(dataB64,pem,padding) -> base64` | `.rsaEncrypt` |
| `__music_source_set_timeout__` | `(id:number, delayMs:number) -> void` | `BASS` 无关，见 Bridge |
| `__music_source_clear_timeout__` | `(id:number) -> void` | 同上 |

native 侧调用 JS 只有 3 个入口：
- `globalThis.music_source_setup(metadataJson)`
- `globalThis.__music_source_handle__("resolve", json)`
- `globalThis.__music_source_handle__("httpResponse", json)`
- `globalThis.__music_source_handle__("timeout", "<id 字符串>")`
  ⚠️ timeout 的 payload 在 Android 上是 `String.valueOf(id)`，preload 里做 `Number(dataJson)`。
  iOS 也必须传**字符串**，传数字虽然也能 `Number()` 但为保持字节级一致，统一传字符串。

native 侧收到的 action（来自 `__music_source_native_call__`）：
`init` / `resolveResult` / `httpRequest` / `httpCancel` / `updateAlert` / `log`

**preload.js 有两份拷贝，必须保持字节一致：**
```
android/app/src/main/assets/music_source_preload.js
packages/music_source_runtime/ios/Resources/music_source_preload.js
```
CI 里有 `diff` 校验会拦不一致。当前两边 md5 都是 `9507edf0e2d584e203de5890667bb6e9`。

---

## 4. 关键选型与理由

### 4.1 音频引擎选 BASS（与 Android 同引擎）

不是「最快跑通」，是唯一能 1:1 保住现有 Dart 契约的选项：

| 约束 | 只有 BASS 满足 |
|---|---|
| 错误码格式 `BASS_<int>` | Android 侧直接透传 `BASS_ErrorGetCode()`，Dart 用正则解析 |
| 均衡器语义 | Dart 的 `BassEqualizerBand` 是 biquad（peaking/lowShelf/highShelf/lowPass/highPass + Q），对应 BASS_FX 的 BQF |
| `bufferedPosition` | 用 `BASS_StreamGetFilePosition(FILEPOS_END/DOWNLOAD)` 按比例映射，语义特定 |
| 格式覆盖 | ape / wv / opus / dsd / flac 全都要（音源常给 ape 与 DSD） |
| format 特化调用 | `BASS_FLAC_StreamCreateURL` / `BASS_APE_StreamCreateFile` 等分支逻辑 |

AVPlayer 只能覆盖 mp3/aac/alac/flac/wav，**没有 ape**；且没有等价的双向 biquad 参数化。

**BASS 在 Apple 平台的差异（重要）：**
- ALAC / AAC 由 BASS 核心走 CoreAudio，**没有 iOS 版 bassalac**（`bassalac24-ios.zip` 不存在）
- HTTPS 由 BASS 内置安全传输处理，**没有 iOS 版 bass_ssl**
- **没有 iOS 版 BASS_FX** → 均衡器改为自研 C 实现 `CyShineBiquad.c`（RBJ cookbook 系数，
  与 BASS_FX BQF 同源），挂在 `BASS_ChannelSetDSP` 上

可下载的 iOS 包（已实测 200）：

| 包 | 用途 |
|---|---|
| `bass24-ios.zip` | 核心 |
| `bassflac24-ios.zip` | FLAC |
| `bassape24-ios.zip` | Monkey's Audio |
| `bassopus24-ios.zip` | Opus |
| `basswv24-ios.zip` | WavPack |
| `bassdsd24-ios.zip` | DSD |

包内结构：`<name>.xcframework/{ios-arm64_armv7_armv7s, ios-arm64_i386_x86_64-simulator}/<name>.framework/<name>`
——**xcframework 里不含头文件**，头文件在 zip 根目录。所以项目里必须有
`Classes/CHeaders/CBassShim.h` + `module.modulemap` 把 bass*.h 聚合成 `CBass` 模块供 Swift import。

BASS 二进制**不入库**（官方再分发限制），由 `tool/fetch_bass_ios.sh` 构建时下载。

### 4.2 JS 引擎选 JavaScriptCore

| 维度 | JavaScriptCore（选用） | QuickJS（Android 用的） |
|---|---|---|
| 依赖 | iOS 系统自带，零依赖 | 需要 vendor 源码/二进制（quickjs-ng 有 amalgam 包） |
| 插件 API | 纯净、有 Swift 互操作 | 需要 ObjC++/C 桥 |
| 脚本语义 | ES2020+，preload.js 只用标准语法 | 同 |
| 风险 | 与 Android 引擎不同，极端脚本可能有差异 | 与 Android 完全一致 |

结论：用 JSCore 起步。`preload.js` 只依赖标准 ES2017+ 与自身注入的 native 函数，
两端行为应当一致。若日后遇到某个音源在 JSCore 下异常，只需替换
`SourceScriptSession.makeContext()`，通道逻辑一行不用动。

**JSCore 的两个实现细节（踩坑预埋）：**
1. `@convention(block)` 闭包要用 `unsafeBitCast(closure, to: AnyObject.self)` 才能
   `setObject(_:forKeyedSubscript:)`。
2. native 函数抛错误要映射成 JS 异常：在 block 里取 `JSContext.current()`，
   把 `JSValue(newErrorFromMessage:in:)` 赋给 `context.exception`，然后返回空字符串。
   直接用 Swift throw 不会变成 JS 异常。
3. JSCore 的微任务队列在 API 入口（`evaluateScript` / `call`）结束后冲刷；
   `httpResponse` 回灌后额外跑一次 `Promise.resolve();` 兜底。

---

## 5. iOS 造成的能力损失（平台限制，不是实现问题）

| 能力 | Android | iOS |
|---|---|---|
| 扫全盘音乐 | `MANAGE_EXTERNAL_STORAGE` | ❌ 沙盒；只能 App Documents + 用户文档选择器授权的目录 |
| 应用内自更新 | 下载 APK 安装 | ❌ 只能跳 App Store |
| 换图标 | `activity-alias` 无提示切换 | ⚠️ `setAlternateIconName`；图标必须走**资产目录**（见第 8 节 #32），**切换会弹系统提示** |
| 媒体库扫描 | `MediaScannerConnection` | ❌ 无等价机制（`media_scan.scan` 直接返回 true） |
| 主 App 驱动桌面卡片 | `AppWidget` RemoteViews | ⚠️ WidgetKit 跑在独立进程，只能经 App Group 共享数据；**免费签名没有 App Groups 能力** → 小组件停在引导态（灵动岛不受影响，见第 8 节 #29） |
| 灵动岛 / 实时活动 | ❌ 无对应机制 | ✅ ActivityKit（iOS 16.2+）；传输按钮用 `Link` 回调 App，代价是会切前台 |
| 主动退到后台 | `moveTaskToBack` | ❌ iOS 不允许 |
| 后台常驻 | 前台服务 | ⚠️ 仅 `UIBackgroundModes: audio`（已在 Info.plist 配好） |

---

## 6. 已完成 / 未完成

### 6.1 已完成（本轮）

| 项 | 文件 |
|---|---|
| iOS 工程生成 + Bundle ID 改为 `com.cyshine.music` | `ios/` |
| Info.plist：后台音频、文件共享、ATS、文档类型（**不含任何图标键**） | `ios/Runner/Info.plist` |
| AppDelegate / SceneDelegate：注册 Runner 插件 + 外部音频回调 + `cyshinemusic://` 深链 | `ios/Runner/AppDelegate.swift`、`SceneDelegate.swift` |
| Runner 6 通道 iOS 实现 | `ios/Runner/CyShineNativePlugin.swift` |
| 原生 → Dart 日志桥（把原生失败暴露到 App 内「日志」页） | `ios/Runner/CyShineNativeLog.swift` + `lib/core/services/native_log_bridge.dart` |
| bass_player iOS：通道全方法 + 事件流 + biquad 均衡器 + BASS 同步点 | `packages/bass_player/ios/` |
| music_source_runtime iOS：双通道 + 8 native 函数 + JSCore + 定时器 | `packages/music_source_runtime/ios/` |
| music_home_widget iOS：通道 + App Group 写入 + WidgetCenter 刷新 | `packages/music_home_widget/ios/` |
| 加密层（md5/base64/AES/RSA + DER 解析） | `Classes/MusicSourceCrypto.swift` |
| BASS 二进制与头文件拉取脚本 | `tool/fetch_bass_ios.sh` |
| 备用图标生成（纯标准库 PNG 缩放） | `tool/fetch_app_icons.{sh,py}` |
| Xcode 工程接入脚本（幂等，按文件名去重） | `tool/patch_xcodeproj.py` |
| CI：macOS 出未签名 IPA | `.github/workflows/ios-build.yml` |
| Dart 侧修正 3 处 | 见 6.2 |
| 点状态栏回顶（自接 `handleStatusBarTap`） | `lib/core/ui/scroll_to_top.dart` |
| 灵动岛 / 锁屏实时活动 + 桌面小组件 | `ios/CyShineMusicWidget/`、`ios/Runner/CyShineLiveActivityBridge.swift`、`lib/features/player/live_activity_service.dart`；详见 6.4 |
| Widget Extension 独立编译并嵌入 | `tool/build_widget_extension.sh` + CI 的 `Build & embed widget extension` |

### 6.2 Dart 侧改动（全部）

| 文件 | 改动 | 原因 |
|---|---|---|
| `lib/app.dart` | 新增 `_supportsPlatformDynamicColor` + `_platformDynamicColorBuilder`；`_corePaletteFuture` 加平台守卫与 onError | `dynamic_color` pub.dev 平台声明**没有 ios**，直接调用会抛 MissingPluginException |
| `lib/app.dart` | 补 `import 'package:flutter/foundation.dart';` | `kIsWeb` / `defaultTargetPlatform` 需要 |
| `lib/core/services/app_icon_service.dart` | `supportsCustomAppIcons` 放开 iOS | 走 `setAlternateIconName` |
| `lib/core/services/storage_browser_service.dart` | `isSupported` 放开 iOS | 沙盒目录仍可浏览 |
| `packages/bass_player/lib/bass_player.dart` | 平台守卫加上 iOS | 真机上「搜歌播放」曾抛 `BASS playback is available on Android only`（第 8 节 #20） |
| `lib/core/services/tagger_platform_flutter.dart` | 读写两边都放开 iOS | 否则 FLAC 标签写不了 |
| `lib/core/ui/scroll_to_top.dart`（新增） | 自接 `handleStatusBarTap()`，收集存活的 `ScrollPosition` 回顶 | 框架实现被外壳 Scaffold 挡住（第 8 节 #22） |
| `lib/features/player/live_activity_service.dart`（新增） | 实时活动的 Dart 侧驱动 | 见 6.4 |
| `lib/main.dart` / `lib/app.dart` | 初始化 LiveActivityService；iOS 上激活 `liveActivitySyncProvider`；接管 `openPlayer` | 见 6.4 |
| `lib/core/services/native_log_bridge.dart`（新增） | 监听 `cy_shine_music/native_log`，写进 `AppLogger` | Release 包上 `NSLog` 不落 App 内日志页，真机排查是盲区（第 8 节 #31） |
| `lib/main.dart` | `runApp` 前先 `NativeLogBridge.install()` | 越早装上，后面的原生失败才进得了日志页 |
| `lib/core/services/app_logger.dart` | `logAndroidDiagnostics()` 内部按平台分流到 `ios-runtime` | **方法名沿用上游不动**（少一处 rebase 冲突），但原生 `app_task.diagnostics` 的 iOS 实现早就有，只是被 `Platform.isAndroid` 挡住了。放开后每次播放状态变化都会采一份机型/系统版本/通知开关/低电量（第 8 节 #40） |

`dart analyze lib packages` 结果：**1 issue**，是上游既有的 `onReorder` 弃用提示，与本次改动无关。

### 6.3 未完成（下一步）

| 优先级 | 事项 | 说明 |
|---|---|---|
| ~~P0~~ | ~~真机运行联调~~ | ✅ 已完成。真机已装上并跑起来；导入音源超时、搜歌播放、点状态栏不回顶三个 bug 已修 |
| ~~P0~~ | ~~WidgetKit 卡片 UI + 灵动岛~~ | ✅ 代码已完成，见 6.4；**待真机复测 `ios-v2.0.1`** |
| **P0** | **灵动岛真机复测**（当前卡点） | v2.0.1 已做：★ **补上从未请求过的通知授权**（最可能的根因，见第 8 节 #40）、诊断加 `机型`/`通知`/`Bundle` 三项判据、日志页放开 iOS 原生诊断。此前已做：失败回灌日志页、扩展 plist 补 `NSSupportsLiveActivities`、开关改成「播放时重试」、扩展版本对齐。**复测前先排除三个非代码原因**（见第 8 节 #37/#38/#42）：前台 App 不显示自己的实时活动、灵动岛是 iPhone 14 Pro+ 的硬件、侧载扩展要重启一次 iPhone |
| **P0** | **侧载能否支持扩展的定性** | 免费签名的侧载工具若不给 `.appex` 配 App ID、重签时丢掉 `PlugIns/`、或只改主 App 的 bundle id 漏改扩展的（第 8 节 #41），扩展根本加载不了 → 灵动岛与桌面小组件一起失效，而主 App 一切正常。**判据**：桌面长按 → 添加小组件 → 搜索「栖弦」；以及日志页 `live-activity` 那行的 `扩展=` 与 `Bundle=` 两项 |
| P1 | iOS 写 mp3 标签 | 现在对非 ISO-BMFF 格式**明确报错**（不写坏文件）。方案：引入 `pod 'ID3TagEditor', '~> 5.5'`（纯 Swift，支持 ID3 读写 + 内嵌图）或 TagLib |
| P1 | ISO-BMFF（m4a）标签写入 | `CyShineNativeTaggerChannel.writeTags` 里留了分支，需接 `AVAssetExportSession` 元数据重写 |
| P2 | App Group entitlement（桌面小组件的真实数据） | `group.com.cyshine.music` 需要**付费账号**的 App Groups 能力；免费签名拿不到，小组件会停在引导态（已降级，不白屏）。灵动岛不受影响 |
| P2 | 灵动岛的封面 | 同上：封面走 App Group，没能力时回退到内置音符占位图 |
| P2 | `audio_intent` 的 `openAudio` | 现在用 `UIActivityViewController`（分享面板）；Android 是 `ACTION_VIEW` 选播放器，iOS 只能这样 |
| P3 | 本地曲库的目录授权 UI | 原生已提供 `addRoot`/`removeRoot`（bookmark 持久化），但 Dart 侧的 `storage_folder_picker_sheet` 还没有 iOS 分支去调它 |
| P3 | `ScrollView.keyboardDismissBehavior` | 默认 `manual`，iOS 用户习惯 `onDrag`（第 8 节 #23） |

> 注：`lib/features/player/music_home_widget_service.dart:44` 的
> `if (!Platform.isAndroid) return;` **保持不动** —— iOS 的桌面小组件数据由
> `CyShineLiveActivityBridge` 在原生侧写入 App Group，不需要 Dart 再走一遍。

### 6.4 Widget Extension（灵动岛 + 桌面小组件）

```
                    Dart（lib/features/player/live_activity_service.dart）
                                  │  MethodChannel cy_shine_music/live_activity
                                  │  start / update / end        ▲ control / openPlayer
                                  ▼                              │
        ios/Runner/CyShineLiveActivityBridge.swift  ─────────────┘
                    │  Activity<CyShineActivityAttributes>
                    │  写封面到 App Group：artwork/current.jpg
                    │  写状态到 App Group UserDefaults：widget.*
                    ▼
        ┌───────────────────────────────────────────────┐
        │  Runner.app/PlugIns/CyShineMusicWidget.appex  │
        │  ├─ CyShineLiveActivityWidget  灵动岛/锁屏    │
        │  └─ CyShineHomeWidget          桌面小组件     │
        └───────────────────────────────────────────────┘
```

| 文件 | 归属 | 作用 |
|---|---|---|
| `ios/CyShineMusicWidget/CyShineActivityAttributes.swift` | **两个目标都编译** | `ActivityAttributes` + `ContentState`。同一份源码编译进 Runner 与扩展，保证类型一致（系统靠类型匹配已启动的活动） |
| `ios/CyShineMusicWidget/CyShineLiveActivityWidget.swift` | 扩展 | 灵动岛展开/紧凑/最小态 + 锁屏卡片 + 封面/进度条/传输按钮 |
| `ios/CyShineMusicWidget/CyShineHomeWidget.swift` | 扩展 | 桌面小组件（small / medium），读 App Group UserDefaults |
| `ios/CyShineMusicWidget/CyShineWidgetBundle.swift` | 扩展 | `@main` 入口，导出上面两个 |
| `ios/Runner/CyShineLiveActivityBridge.swift` | Runner | 通道 + ActivityKit 生命周期 + 封面落盘 + App Group 写入 |
| `tool/build_widget_extension.sh` | 构建 | `xcrun swiftc` 独立编译 → 塞进 `PlugIns/` |

**三条设计取舍（改之前先读）：**

1. **更新频率压到最低。** Dart 只在「换歌 / 播放暂停 / 跳转 / 位置跨过 5 秒」时推一次；
   播放中的进度条由原生侧 `ProgressView(timerInterval:)` 自己推进
   （用 `ContentState.playbackStart/playbackEnd` 算出区间）。
   实时活动每秒推更新既费电又会被系统限流。
2. **控制按钮用 `Link` + `cyshinemusic://` 而不是 AppIntent。** `Link` 在 16.2 就能用，
   代价是点一下会把 App 切到前台。锁屏上本来就有系统播放控件，够用。
   URL 由 `AppDelegate` / `SceneDelegate` 接住 → `CyShineIncomingAudio.handleAppURL`
   → 桥接 `handleIncomingURL` → 回灌 `control` 给 Dart。
3. **桌面小组件降级到引导态而不是白屏**（见第 8 节 #29）。
4. **一切「为什么没显示」都写进一条诊断。** `CyShineLiveActivityBridge.diagnostics()`
   在 `isSupported` / 发起失败 / 每次播放状态变化时经 `cy_shine_music/native_log`
   回灌到 App 内「日志」页（`live-activity` 标签），一行里包含：

   | 字段 | 判什么 |
   |---|---|
   | `iOS <版本>` | 低于 16.2 直接没有实时活动 API |
   | `机型=iPhone15,3(灵动岛机型)` | 灵动岛只存在于 iPhone 14 Pro 及以上；刘海屏机型只在锁屏显示 |
   | `开关=true/false` | `ActivityAuthorizationInfo().areActivitiesEnabled`，用户在设置里关掉了 |
   | `通知=已授权/未询问/被拒绝` | 见第 8 节 #40 —— 未询问 = 实时活动不会显示 |
   | `在跑的活动=N` | 活动有没有真的建起来 |
   | `扩展=在/缺失,二进制在/缺失` | 侧载工具把 `PlugIns/` 丢了吗（#36） |
   | `Bundle=a/b ⚠前缀不匹配` | 重签漏改扩展 id（#41） |
   | `AppGroup=可用/不可用` | 封面来源；不可用则占位图 |

   用户只要截这一行，几乎就能直接定性，不用在真机上来回猜。

---

## 7. 验收命令与期望值

### 7.1 本地（Windows 上可做的部分）

| 命令 | 期望 |
|---|---|
| `bash tool/fetch_bass_ios.sh` | 输出 6 个 `Frameworks/*.xcframework` + 6 个头文件；无 `[warn] 缺少头文件` |
| `bash tool/fetch_app_icons.sh` | `主图标 19 个` + `备用图标 90 个`（5 套 × 18）+ `兜底副本 15 个` |
| `python3 tool/patch_xcodeproj.py` | `[ok] Swift 4 个 + 图标 15 个 -> 引用校验通过`；重复执行同样输出（幂等） |
| `dart analyze lib packages` | 1 issue（上游既有的 onReorder 弃用） |
| `diff android/app/src/main/assets/music_source_preload.js packages/music_source_runtime/ios/Resources/music_source_preload.js` | 无输出 |

### 7.2 CI（macOS runner，已实测通过）

| 步骤 | 期望 |
|---|---|
| Setup Flutter | 装 3.47.7 |
| Fetch BASS iOS binaries | 6 个 xcframework |
| Verify preload.js parity | md5 一致 |
| Prepare iOS alternate icons | 主 19 + 备用 90 + 兜底 15 个 PNG |
| **Resolve iOS version** | 读 `tool/ios_version.txt`；非法内容直接失败 |
| Ensure Xcode project wiring | pbxproj 引用 + 部署目标 + 资产目录图标构建设置 |
| Analyze | 1 issue（同上） |
| Pod install | 3 个本地 pod 全部 Installing，无「未找到 BASS iOS 二进制」 |
| Dump pod link settings | 诊断输出（失败时用） |
| Build iOS (no codesign) | success |
| Build & embed widget extension | `[ok] 扩展已嵌入`，`lipo -info` 输出 arm64，并打印注入后的版本号 |
| Verify embedded extension | `PlugIns/CyShineMusicWidget.appex` + 主二进制 + `com.apple.widgetkit-extension` + `NSSupportsLiveActivities` + **扩展与主 App 的 `CFBundleVersion` 相等** |
| Verify alternate app icons | **告警级**（不拦出包）：打印 `CFBundleIcons` 与 `Assets.car` 里的图标集，能一眼看出 Xcode 有没有采纳 |
| Package / Upload unsigned IPA | `CyShineMusic-unsigned.ipa`，Step summary 带版本号 |

### 7.3 产物自检（已做过一次，可复现）

| 检查 | 期望 |
|---|---|
| `unzip -l *.ipa \| grep Frameworks/` | 含 `bass/bassflac/bassape/bassopus/basswv/bassdsd` + 3 个插件 framework |
| IPA 内 `Info.plist` | `CFBundleIdentifier=com.cyshine.music`、`CFBundleDisplayName=栖弦`、`UIBackgroundModes=[audio,fetch]` |
| IPA 内 `Info.plist` 的 `CFBundleIcons` | `CFBundlePrimaryIcon.CFBundleIconName=AppIcon`；`CFBundleAlternateIcons` 有 5 项 `AppIcon<Name>`（**由 Xcode 从资产目录生成，不是手写的**） |
| `Payload/Runner.app/Assets.car` | 用 `assetutil --info` 能看到 5 个备用图标集 |
| `music_source_runtime.framework/music_source_preload.js` | 存在 |
| `Payload/Runner.app/PlugIns/CyShineMusicWidget.appex/` | 存在 `CyShineMusicWidget` 主二进制 + `Info.plist`（`NSExtensionPointIdentifier=com.apple.widgetkit-extension`、`NSSupportsLiveActivities=true`） |
| IPA 内 `Info.plist` | 另含 `NSSupportsLiveActivities=true`、`CFBundleURLTypes` 里有 `cyshinemusic` |
| `MinimumOSVersion`（App 与 appex） | 两边都是 16.2 |
| `CFBundleShortVersionString` / `CFBundleVersion`（App 与 appex） | 两边一致；version 来自 `tool/ios_version.txt`，build 来自 CI run number |
| 主 App 与扩展的 `CFBundleIdentifier` 前缀 | 扩展 id 必须以主 App id 为前缀（`com.cyshine.music.widget` ⊃ `com.cyshine.music`）。**侧载重签后这一条可能失效**，见第 8 节 #41 |

最近一次实测（`ios-v2.0.1` / build 17，15,769,066 B，md5 `8b1d9f65107c1ccb518bf9f62a8235df`）：
上面每一项都通过 —— 主 App `com.cyshine.music` 2.0.1/17、扩展 `com.cyshine.music.widget`
2.0.1/17、`MinimumOSVersion` 都是 16.2、两侧 `NSSupportsLiveActivities=true`、
5 个备用图标都在 `CFBundleAlternateIcons`、扩展二进制在 `PlugIns/`。

Windows 上用 Python 就能核对（`zipfile` + `plistlib`，注意给 **Windows 路径**，
Git Bash 的 `/tmp/...` Python 认不了）：

```python
import zipfile, plistlib
z = zipfile.ZipFile(r'F:\codex项目\音乐源播放器\dist\CyShineMusic-unsigned.ipa')
p = plistlib.loads(z.read('Payload/Runner.app/Info.plist'))
q = plistlib.loads(z.read('Payload/Runner.app/PlugIns/CyShineMusicWidget.appex/Info.plist'))
```

---

## 8. 踩坑记录

1. **`flutter create --platforms=ios .` 会往 `test/` 塞一个默认 `widget_test.dart`**，
   它与上游测试冲突（引用不存在的 counter app）。已删除。同时会生成 `cy_shine_music.iml`，也删了。
2. **生成的 Bundle ID 是 `com.cyshine.cyShineMusic`**，与 Android 的 `com.cyshine.music` 不一致，
   已 `sed` 统一。
3. **BASS 的 xcframework 不含头文件**，第一版 podspec 直接 `vendored_frameworks` 会编译失败。
   必须额外提供 `CBassShim.h` + `module.modulemap` + `SWIFT_INCLUDE_PATHS`。
4. **BASS 的 `windows`/`linux`/`macos` 包和 iOS 包命名不同**：`bassalac24.zip` 是 Windows 包
   （里面有 `bassalac.dll`），别拿错。
5. **un4seen.com 会间歇性返回 404**（限流），探测包名时要 `--retry`。`bass_fx24-ios.zip` /
   `bassssl24-ios.zip` 实测确实不存在，不是限流问题。
6. **preload.js 的 `unofficial` 细节**：`music_source_setup` 里会 `delete` 掉全部 8 个 native
   全局函数，所以只注册一次、且必须在 `evaluateScript(preload)` 之前注册好。
7. **`patch_xcodeproj.py` 的幂等判断不能用裸 ID**：ID 会先作为 `fileRef` 出现，
   导致中间的 `PBXFileReference` 步骤被误跳过（第一版就踩了，`project.pbxproj` 里少了文件引用定义）。
   必须用「完整定义字符串」判断。
8. **Swift 侧 `handle(_:result:)` 是 `FlutterPlugin` 的可选协议要求**，撞名会报
   「must be declared public because it matches a requirement in public protocol 'FlutterPlugin'」，
   而且还会连带产生一串误导性的 `Call can throw` 报错。改名 `handleCall` 即可。
   涉及两个文件：`BassPlayerPlugin`、`MusicHomeWidgetPlugin`。
   （`MusicSourceRuntimePlugin` 里的同名方法是定义在非 FlutterPlugin 的辅助类上，所以没事。）
9. **Swift 在 `DispatchQueue.async` 嵌套下会把「传给 throwing 闭包参数的尾随闭包」误判成非
   throwing**，报一串 `Call can throw, but it is not marked with 'try'`。
   对策：不要在 `async` 闭包里写 `helper(result) { self.throwingCall() }`，
   直接在队列闭包里 `do/catch`。`BassPlayerPlugin.handleCall` 与
   `MusicSourceRuntimePlugin` 现在都是这个写法。（有显式 `try` 的闭包不会踩，例如
   `guardJS { try MusicSourceCrypto.md5(x) }` 一直是好的。）
10. **`BASS_DSD_StreamCreateURL/File` 比其它附加库多一个 `freq` 参数**（0 = 保持源采样率）。
    报错形如 `Missing argument for parameter #6`。flac/ape/wv/opus 都是 5 个参数。
11. **`cancelledCode` 之类的字面量常量要显式声明 `Int32`**，否则会被推成 `Int` 而
    `BassError.code`（`Int32`）不匹配。
12. **`CommonCrypto` 不是独立 framework**，写进 podspec 的 `s.frameworks` 会导致
    `framework not found CommonCrypto`。iOS SDK 里它只是个 modulemap，符号在 libSystem。
13. **`vendored_frameworks` 在「Flutter Podfile(use_frameworks!) + 本地 path 插件 +
   非标准 xcframework 切片名(ios-arm64_armv7_armv7s)」下不生成 `-framework` 链接参数**，
    症状是链接期几十个 `Undefined symbol: _BASS_*`。必须在 `pod_target_xcconfig` 里显式给
    `FRAMEWORK_SEARCH_PATHS`（指向含 `.xcframework` 的目录）与 `OTHER_LDFLAGS`。
14. **备用图标必须落在 `Runner.app/` 根目录**。iOS 解析 `Info.plist` 的 `CFBundleIconFiles`
    是在 bundle 根目录找图，放进 `Runner.app/Icons/` 会找不到。
    所以 `patch_xcodeproj.py` 是按单个文件加入 Copy Bundle Resources（Xcode 会平铺拷贝），
    而不是用「文件夹引用」（文件夹引用会保持子目录结构）。
    脚本里带了迁移逻辑，会把早期版本的文件夹引用行删掉。
15. ★★★ **音源运行时三步的顺序不能错：`preload.js` → `music_source_setup(metadata)` → 音源脚本。**
    `globalThis.lx` 是第二步里才创建的。我第一版写成了 `preload → 音源脚本 → setup`，
    于是脚本一上来执行 `lx.on(...)` 就抛 `lx is not defined`。
    对照 `MusicSourceRuntimeBridge.createRuntime()` 的 Java 顺序，一秒就能看出来。
    **回归测试：`node tool/verify_preload_protocol.mjs` 的场景 B 专门断言这个错误现象。**
16. ★★★ **JSCore 设了 `exceptionHandler` 之后，异常不一定还留在 `context.exception` 里。**
    我原来只靠 `throwIfPendingException(context)` 判断有没有异常 → 拿到 nil → 判定「没异常」
    继续往下跑，把异常整个吞掉。后果是 #15 这种错误只表现为一句「音源初始化超时」，
    完全无法定位。
    对策（两件都要做）：
    ① 在 `exceptionHandler` 里自己记一份 `lastScriptException`，
       并在 load / resolve 还没兑现时**直接把失败抛回 Dart**；
    ② 超时信息里带上 `lastScriptException`。
17. **`metadata` 必须包含 `rawScript`（音源脚本原文）**。Android 会传，
    preload 把它暴露成 `lx.currentScriptInfo.rawScript`，相当多的音源靠它做版本识别 /
    更新检查。漏了会让这些音源在初始化阶段异常。
18. **Android 的 `MAX_SCRIPT_LENGTH = 2 MB`、`sendLog` 截断 2000 字符、`requestId` 用 UUID**
    这些都要跟着对齐；尤其脚本为空时如果不校验，会一路静默走到超时。
19. **排查真机问题时最快的入口是 app 内的「日志」页**（`lib/features/debug/debug_log_page.dart`）。
    iOS 侧已经把 JS console、JS 异常、以及加载流程的关键节点都通过
    `{type:'log', level, message}` 事件发给了 Dart，会被写进 `AppLogger`。
    排查顺序：先看 `music-source` 标签有没有 JS 异常，再看流程走到哪一步。
20. ★★★ **别忘了 Dart 插件层里的平台守卫。** `packages/*/lib/*.dart` 里也有
    `defaultTargetPlatform != TargetPlatform.android` 这类判断，它们不报编译错、也能装包，
    但一调用就抛 `UnsupportedError`。真机上「搜歌播放」报
    `Unsupported operation: BASS playback is available on Android only` 就是
    `packages/bass_player/lib/bass_player.dart` 的 `_initialize()` 里的守卫。
    **做法：把 `platforms` 加成 iOS 之后，务必回头 grep 一遍
    `TargetPlatform.android|Platform.isAndroid|UnsupportedError`。**
21. **`metadata` 里的 `rawScript`（见 #17）与脚本长度校验（#18）都来自 Android 的
    `createRuntime()`**，改这块前先把那个 Java 方法读一遍，逐行对齐最省事。
22. ★★★ **iOS「点状态栏回到顶部」在 `ShellRoute` + `StatefulShellRoute.indexedStack`
    结构下会被外壳 Scaffold 挡住。** 这是 iOS 独有的，纯 Android 开发发现不了。
    Flutter 的链路是：iOS 引擎发 `handleScrollToTop` → `WidgetsBinding` 派发给
    `WidgetsBindingObserver.handleStatusBarTap()` →
    `_ScaffoldState.handleStatusBarTap()` 滚 `PrimaryScrollController`。
    但它有两道门槛，本项目都过不去：
    ① **要求 Scaffold 在屏幕原点 (0,0) 可命中**（框架的 `_HitTestableAtOrigin`，
    用来替代早期的「原点假触摸」方案）。外壳 Scaffold 也在 (0,0) 画了自己的
    statusBar 槽（仅 iOS 注册、opaque 的 `MetaData`），命中测试到它就停了，
    内层页面永远轮不到；
    ② 要求 `PrimaryScrollController` 有已挂载的 client，而外壳 Scaffold 拿到的是
    ShellRoute 那个路由级 controller，页面用的是各自分支路由的，`hasClients` 为 false。
    **症状**：手势事件其实到了，但谁的列表都不动。
    **对策**：`lib/core/ui/scroll_to_top.dart` 自己接 `handleStatusBarTap()`，
    用滚动通知（`ScrollMetricsNotification` 管首帧、`ScrollNotification` 管用户滚动）
    收集存活的 `ScrollPosition`，只动「纵向且 pixels > 0」的那些。
    挂在 `MaterialApp.builder` 最外层，一处覆盖所有路由。
    诊断：`scroll` 标签的日志会写「候选 N 个 / 需要回顶 M 个」——
    没有这行说明引擎没发事件，有这行但 M=0 说明列表没被收集到。
23. **iOS 上很多「手感想当然」的东西都要单独核验**，因为它们都是框架按平台分支实现的，
    在 Android 上跑得好不代表 iOS 也对：点状态栏回顶（#22）、
    状态栏图标明暗（`SystemUiOverlayStyle.statusBarBrightness`）、
    侧滑返回（`PageTransitionsTheme` 的 iOS 默认已是 Cupertino，本项目没覆盖所以正常）、
    惯性回弹（`ScrollBehavior` 平台分支）、键盘收起行为（`ScrollView.keyboardDismissBehavior`
    默认是 `manual`，iOS 上用户习惯 `onDrag`）。
24. ★★★ **实时活动（ActivityKit）的可用性门槛是 iOS 16.2，不是 16.1。**
    16.1 只放开了 `Activity.activities`、`ActivityAuthorizationInfo` 与灵动岛 UI；
    **发起 / 更新 / 结束活动**这一组（`Activity.request(attributes:content:pushType:)`、
    `Activity.update`、Activity`end(_:dismissalPolicy:)`、`ActivityContent`）都是 **16.2** 才有。
    按 16.1 写会得到一串
    `'xxx' is only available in iOS 16.2 or newer`（本项目一次报了 7 个）。
    **门槛要同时改四处**：`tool/patch_xcodeproj.py` 的 `DEPLOYMENT_TARGET`、
    `tool/build_widget_extension.sh` 的 `MIN_IOS`、
    Runner 侧 `@available` / `#available`、以及 Widget 扩展侧的 `@available`。
25. ★★★ **`patch_xcodeproj.py` 的去重必须按「文件名」而不是「稳定 ID」。**
    脚本用 md5 派生 ID（`C7A0F0…`），但历史上手工加过一批 ID 是手敲的（`C7A0E0…`）。
    只比对 ID 的话，每次运行都会再插一份：
      * 同一个 `.swift` 出现在 Compile Sources 两次 → 链接期 **duplicate symbol**；
      * 同一张图标出现在 Copy Bundle Resources 两次 →
        **Multiple commands produce '.../Runner.app/icon_xxx.png'**。
    对策：先按文件名把旧条目**全部清掉**（`strip_managed_entries`），再用稳定 ID 重建。
    这样无论旧 ID 是什么都能收敛，重复执行也不会叠加；脚本末尾还加了
    「该文件名在构建阶段里应恰好出现 1 次」的显式校验。
26. **Widget Extension 刻意不进 `Runner.xcodeproj`。** Flutter 生成的 pbxproj 里加一个
    app-extension target 要改十几处（新 target + 依赖 + Embed App Extensions phase +
    一堆构建设置），写错会把**主 App 的构建也弄坏**。
    这里改成 `tool/build_widget_extension.sh` 用 `xcrun swiftc` 独立编译
    （`-application-extension -parse-as-library`，arm64 + `MIN_IOS`），
    再把 `.appex` 拷进 `Runner.app/PlugIns/` —— 等价于 Xcode 的 embed 阶段。
    好处是扩展失败最多只是没有小组件，主 App 照常出包。
    手工组装 `.appex` 时记得用 PlistBuddy 补 `MinimumOSVersion` 与
    `CFBundleSupportedPlatforms`（Xcode 平时是打包时注入的）。
27. **`WidgetBundleBuilder` 里不要用 `if #available` 做条件分支。**
    结果构建器对条件分支的支持在不同 Xcode 版本上不一致（早期没有 `buildIf`，
    直接编译失败）。正确做法：靠扩展自身的 `MinimumOSVersion` 拦版本，
    然后在 bundle 里**无条件**列出所有 widget。
28. **`ActivityAttributes` 里只能放「活动生命周期内不变」的东西。**
    `attributes` 在 `Activity.request` 时就固定了，而音频时长往往是**播放开始之后**
    才解析出来的。曾经想放一个 `hasDuration` 决定是否显示进度条 —— 那样会导致
    进度条永远不出现。UI 一律直接看 `ContentState.durationMs > 0`。
29. **App Group 拿不到时必须降级，不能白屏。** 桌面小组件与灵动岛封面都依赖
    App Group（`group.com.cyshine.music`）共享数据，而**免费签名的描述文件不支持
    App Groups 能力** —— 侧载用户大概率拿不到容器。
    所以：`containerURL(forSecurityApplicationGroupIdentifier:)` 返回 nil 时，
    桌面小组件显示引导态（「打开 App 播放点什么」），灵动岛封面回退到内置占位图。
    **灵动岛本身不依赖 App Group**（歌名/歌手/进度/状态全在 `ContentState` 里随活动传递），
    所以有没有能力都能用。
30. **iOS 部署目标已提到 16.2**（见 #24）。代价是放弃 iOS 15 及更低设备。
    取而代之的好处是：Runner 侧可以直接写 ActivityKit 而不用到处加 `@available` 守卫。
31. ★★★ **原生的失败必须自己回灌给 Dart，否则真机上是彻底的盲区。**
    `NSLog` 在 Release 包上不落 App 内的「日志」页。实时活动第一次没显示时，
    Dart 侧只有一句「推送失败」，原生那边 `Activity.request` 抛了什么谁也不知道 ——
    白折腾好几轮。现在有 `ios/Runner/CyShineNativeLog.swift`（通道
    `cy_shine_music/native_log`），原生关键失败与诊断都经它进 `AppLogger`。
    **新写任何原生失败路径时，记得也往这里写一条。**
32. ★★★ **备用图标不要手工往 `Info.plist` 写 `CFBundleIcons` / `CFBundleAlternateIcons`。**
    散装 PNG + 手工声明这条路（曾经能用）在较新的 Xcode / iOS 上会**静默失效**：
    `setAlternateIconName` 直接报错，或更隐蔽地 —— `supportsAlternateIcons`
    返回 `false`，看起来像「设备不支持」。正确做法（Xcode 官方路径）：

    | 环节 | 做法 |
    |---|---|
    | 图标 | `ios/Runner/Assets.xcassets/AppIcon<Name>.appiconset/`（含 `Contents.json`） |
    | 声明 | 构建设置 `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "AppIconMidnight AppIconSky …"` |
    | 编译 | 必须同时有 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`，否则 actool 只编主图标，备用图标集被整个丢掉 |
    | plist | **不要手写**；Xcode 打包时自动生成 `CFBundleIcons` / `CFBundleAlternateIcons` |

    三处名字（appiconset 目录名 / 构建设置 / Swift 里的候选名）必须逐字一致。
    散装 PNG 仍留在 `ios/Runner/Icons/`（不进包）作为兜底：万一某个 Xcode 不吃
    `ALTERNATE_APPICON_NAMES`，把手工 plist 块加回去即可，不用重新生成图标。
33. **扩展与主 App 的 `CFBundleVersion` 必须一致。** 手工组装 `.appex` 时要显式
    写进去（`build_widget_extension.sh` 读 `IOS_BUILD_NAME` / `IOS_BUILD_NUMBER`），
    否则 iOS 拒绝加载扩展 —— 症状是「灵动岛与桌面小组件一起消失」，而且没有明显报错。
34. ★★ **扩展 `Info.plist` 也要写 `NSSupportsLiveActivities`。** 官方文档只要求主 App，
    但只写主 App 时会出现「`Activity.request` 成功、灵动岛不渲染」的静默失败。
    Flutter 的 `live_activities` 插件文档同样要求两边都写。
35. **实时活动的可用性开关要能「后开」生效。** 系统设置里
    「设置 → 栖弦 → 实时活动」可以随时改变。如果只在 `main()` 里检查一次，
    用户先播放、后去开开关，就必须重启 App —— 表现成「灵动岛怎么都不出现」。
    现在每次播放状态变化都重试一次 `isSupported`（代价是一次轻量通道调用）。
36. **侧载工具可能丢掉 `PlugIns/`。** 免费签名的 AltStore / SideStore 重签时会
    连带处理 app 扩展，但如果用户在签名界面取消勾选，或工具版本有 bug，
    `.appex` 就没了 —— 灵动岛与桌面小组件一起失效。所以诊断里加了
    「扩展是否真的在 `Bundle.main.builtInPlugInsURL` 里」这一条，用户截个日志就能定性。
37. ★★★ **前台运行的 App 永远不会显示自己的实时活动。** 这是 iOS 的设计：
    自己的 App 在前台时占着整个显示区域，灵动岛会收起来。
    **必须在 App 里发起活动后回到桌面 / 锁屏，才能看到**。
    「`Activity.request` 成功」不等于「有人看到了」。
    这一条极容易被误判成「功能没做出来」—— 用户第一次反馈「灵动岛不显示」时，
    他给的就是 App 内日志页的截图（App 正在前台）。
38. ★★ **灵动岛是 iPhone 14 Pro 及以上的硬件。** 刘海屏机型
    （iPhone 13 及更早、14/15/16 非 Pro）实时活动**只在锁屏与通知中心**出现，
    灵动岛位置永远是空的。诊断里特意把 `iOS 版本` 打出来了，但机型要用户自己核对。
39. **锁屏要显示实时活动，还要一个单独的开关**：
    设置 → 面容 ID 与密码 → 锁定时允许访问 → 实时活动。
    只打开「设置 → 栖弦 → 实时活动」时，锁屏可能仍然不显示。
40. ★★★ **实时活动要显示，App 必须先有通知授权 —— 而上游从来没请求过。**
    iOS 17 起，「实时活动」的开关就挂在 App 的通知设置里（设置 → 栖弦 → 通知 → 实时活动）。
    上游是**纯 Android 项目**，`MainActivity.kt` 里没有任何
    `UNUserNotificationCenter.requestAuthorization` 的等价物（Android 8+ 走的是
    通知渠道，不需要运行时授权）。于是 iOS 侧装包后 `UNAuthorizationStatus`
    一直是 `notDetermined` —— **这是「灵动岛怎么都不出现」的高概率根因**，
    而它不报任何错：`Activity.request` 可能成功，`ActivityAuthorizationInfo().areActivitiesEnabled`
    也可能返回 `true`，就是屏幕上什么都没有。

    修法（`CyShineLiveActivityBridge.ensureNotificationAuthorization()`）：
    在**首次发起活动（= 首次播放）**时请求一次 `[.alert, .sound, .badge]`。
    刻意**不放冷启动** —— 一打开 App 就弹权限框体验很差；
    也刻意**不做成同步阻塞** —— 授权弹窗是异步的，首次 `Activity.request`
    照常发起，失败也没关系（Dart 侧 `_activeStarted` 仍是 false，下一次状态变化会重试）。
41. ★★ **侧载重签后要核对主 App 与扩展的 bundle id 前缀。** 重签工具
    （爱思 / AltStore / SideStore / 各种 `codesign` 脚本）常常只把主 App 的
    `CFBundleIdentifier` 换成自己的，`.appex` 里的 id 没跟着改。
    iOS 要求扩展 id 必须以主 App id 为前缀，不匹配就**直接拒绝加载扩展** ——
    症状是「灵动岛不显示 + 桌面搜不到小组件」，**而主 App 一切正常、没有任何报错**。
    诊断里的 `Bundle=<主 App id>/<扩展 id>` 就是给这个用的，不匹配会带
    `⚠前缀不匹配`。另外免费个人签名的 **wildcard App ID 本身就不支持 App Extensions**，
    所以侧载场景下扩展失效是常态，不是代码 bug。
42. **装完包重启一次 iPhone。** 侧载安装的 app 扩展需要 PlugInKit 扫描注册，
    冷启动一次系统不一定立刻认。重启后桌面「+」里才搜得到「栖弦」。

---

## 8.1 本地可跑的验证工具

| 工具 | 用途 |
|---|---|
| `node tool/verify_preload_protocol.mjs` | 用 `node:vm` 隔离跑 `preload.js` 的协议 + 执行顺序。场景 A 走正确顺序断言 `init`/`resolve`；场景 B 断言「顺序写反会抛 `lx is not defined` 且不上报 `init`」。已接入 CI |
| `dart analyze lib packages` | Dart 侧静态检查（期望 1 issue：上游既有的 onReorder 弃用） |
| `python3 tool/patch_xcodeproj.py` | Xcode 工程引用（幂等） |
| `bash tool/fetch_app_icons.sh` | 从 `assets/app_icons/classic.png` 生成全部 iOS 图标（纯标准库，约 6 秒） |
| `node tool/verify_live_activity_auth.mjs` | 实时活动授权链路的回归守卫（第 10 轮新增）。7 项检查，防「授权请求挂在不会被执行的路径上」这类死锁。已接入 CI，并做过负向测试 |

没有 Mac 也能验证的就这五样；Swift 侧只能靠 CI 编译。

### 验证一个 IPA 到底有没有某项能力

拿到别人的 IPA 当参考前，**先证明它真的有那个功能**，否则会把人带偏。
两条独立证据（缺一不可）：

| 维度 | 手段 | 判据 |
|---|---|---|
| 有没有扩展 | 解包后看 `Payload/*.app/PlugIns/` 下有没有 `.appex` | 没有 = 不可能有 Widget/Live Activity |
| 有没有链框架 | 在**主二进制**里数符号的字节出现次数 | `ActivityKit` / `WidgetKit` / `DynamicIsland` / `ActivityConfiguration` 计数为 0 = 没实现 |
| 有没有声明 | Info.plist 查 `NSSupportsLiveActivities` | 缺失 = 没声明（但**反之不成立**：有的 App 硬编码） |

Python 一行版（Windows 上注意 `/tmp` 不可用于 Python，用 `%TEMP%`）：

```bash
unzip -q app.ipa -d "$TEMP/x"
APP=$(find "$TEMP/x/Payload" -maxdepth 1 -name "*.app")
ls "$APP/PlugIns" 2>/dev/null || echo "无扩展"
python -c "
d=open(r'$APP/<主二进制>','rb').read()
for k in [b'ActivityKit',b'WidgetKit',b'DynamicIsland',b'ActivityConfiguration']:
    print(k.decode(), d.count(k))"
```

只查 plist 或只查目录都可能漏：有的 App 把符号硬编码成字符串、
有的把扩展塞在 `Frameworks/` 下而不是 `PlugIns/`。

---

## 8.2 图标体系

```
assets/app_icons/classic.png        1024x1024，唯一源文件（正方形、不透明）
        │
        ├─ tool/fetch_app_icons.py 解析 AppIcon.appiconset/Contents.json
        │   → ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png        主图标
        │
        ├─ 同脚本做 HSV 色相迁移 → 5 套备用图标**资产目录集**（真正生效的那份）
        │   → ios/Runner/Assets.xcassets/AppIcon<Name>.appiconset/*.png
        │
        └─ 同脚本再写一份散装副本（兜底，默认不进包）
            → ios/Runner/Icons/icon_<variant>[@2x|@3x].png
```

**6 套图标的配色**（备用图标由主图标派生；白色音符饱和度≈0，所以清一色保持纯白）：

| variant | 显示名 | hue(0-255) | sat | val | 资产目录图标集名 |
|---|---|---|---|---|---|
| classic | 经典绿 | — | — | — | `AppIcon`（主图标） |
| midnight | 午夜蓝 | 148 | 0.95 | 0.72 | `AppIconMidnight` |
| sky | 晴空蓝 | 136 | 0.90 | 1.06 | `AppIconSky` |
| lavender | 雾紫 | 186 | 0.85 | 0.98 | `AppIconLavender` |
| mint | 薄荷青 | 108 | 0.70 | 1.10 | `AppIconMint` |
| peach | 暖桃粉 | 12 | 0.85 | 1.05 | `AppIconPeach` |

预览图：`recon/icon-family.png`

**几条硬约束：**

1. 主图标的尺寸需求写在 `AppIcon.appiconset/Contents.json`，脚本按 `size × scale` 算像素，
   不硬编码 —— 上游改了 Contents.json 也不用改脚本。备用图标集的 `Contents.json`
   直接复用主图标的 entries（**去掉 `ios-marketing`**：备用图标不需要 1024，带上可能被 actool 判非法）。
2. **写出的 PNG 不带 alpha 通道**（color type 2）。App Store Connect 会因 alpha 拒绝图标，
   我们的图全部不透明。
3. **备用图标走资产目录，不再依赖 `Runner.app/` 根目录的散装 PNG。** 见踩坑 #32：
   手工往 `Info.plist` 写 `CFBundleIcons` 在新 Xcode / 新 iOS 上会静默失效。
   `Runner/Icons/` 只作兜底保留，不需要接进 Copy Bundle Resources。
4. **不要往 `ios/Runner/Icons/` 放非图标 PNG**（比如预览图）——
   该目录仍被 `patch_xcodeproj.py` glob，多余文件会被打进 app bundle。预览图放 `recon/`。
5. 脚本只用标准库（`zlib`/`struct`/`colorsys`）：CI 的 macOS runner 上的 python3
   没有 Pillow，必须能在裸环境跑。
6. **备用图标增删/改名时五处要同时改**（改漏任何一处都会「图标能在设置里选、但点了没反应」）：
   `tool/fetch_app_icons.py` 的 `ALTERNATES` 第 4 列、
   `tool/patch_xcodeproj.py` 的 `ALTERNATE_APPICON_NAMES`、
   `ios/Runner/CyShineNativePlugin.swift` 的 `CyShineAppIconChannel.alternateCandidates`
   与 `codeByIconName`、
   `lib/core/services/app_icon_service.dart` 的 `AppIconVariant` 枚举。
   `Info.plist` **不用动**（由 Xcode 生成）。

---

## 9. 与上游同步的策略

- 只在 `main` 的 tag 上做 rebase，不追每日提交。
- 冲突面刻意收窄到：`README.md` 顶部一段横幅（有 `iOS-PORT-BANNER:START/END` 标记，
  冲突时直接保留本仓库的横幅即可）、`lib/app.dart`（1 处）、`app_icon_service.dart`（1 处）、
  `storage_browser_service.dart`（1 处）、3 个 `pubspec.yaml`（各加 2 行）、
  以及新增的 `ios/` 与 `packages/*/ios/` 目录。
- `ios/` 整体是上游没有的，rebase 时不会被触碰。
- 若上游改了原生通道契约，优先改 `packages/*/ios/` 去适配，**不要改 Dart**——否则冲突面会扩散。

## 10. 分发方式

| 渠道 | 地址 | 说明 |
|---|---|---|
| **GitHub Release（推荐，用户可见）** | https://github.com/chenweitian423/CyShineMusic-iOS/releases/latest | 附件 `CyShineMusic-unsigned.ipa`，仓库首页右侧 Releases 直接可见 |
| Actions Artifact | Actions → 选运行 → 页面最底部 Artifacts | 保留 14 天；`CyShineMusic-unsigned-ipa.zip` 解开是同一个 ipa |
| 本地副本 | `F:\codex项目\音乐源播放器\dist\CyShineMusic-unsigned.ipa` | 与 Release 附件逐字节一致 |

**发新版本的流程**：CI 出包 → 下载 artifact → 取 `.ipa` →
`gh release create <tag> <ipa路径> -R chenweitian423/CyShineMusic-iOS -t "<标题>" -F <说明文件> --latest`。

---

## 11. iOS 版本号体系（与上游解耦）

用户明确要求：「iOS 本来就是独立的，没必要一直是一个版本」。

| 项 | 来源 | 说明 |
|---|---|---|
| `CFBundleShortVersionString` | `tool/ios_version.txt`（**唯一来源**，手工维护） | iOS 从 `2.0.0` 起独立编号，不再跟上游 Android 的 `1.0.8` |
| `CFBundleVersion` | CI 的 `github.run_number` | 自动单调递增，每次出包都不同；不用管 |
| Widget 扩展的两个版本 | `IOS_BUILD_NAME` / `IOS_BUILD_NUMBER` 环境变量 | **必须与主 App 一致**，否则 iOS 拒绝加载扩展（见第 8 节 #33） |
| Release tag | `ios-v<CFBundleShortVersionString>` | 例：`ios-v2.0.1`；标题里带 build number |
| 本地出包 | `--build-name=$(cat tool/ios_version.txt) --build-number=<任意递增数>` | 见 `ios/README-IOS.md` 3.1 |

发版时只需改 `tool/ios_version.txt` 一个地方。
CI 有一步 `Resolve iOS version` 会校验内容必须是 `x` / `x.y` / `x.y.z`，
写错直接失败，不会产出「版本号为空」的包。

**注意：Release 是手动发的。** `ios-build.yml` 只负责出包 + 上传 artifact，
发 Release 使用的是（`.github/workflows/release.yml` 是上游的 Android 流程，已停用自动触发）：

```bash
cd CyShineMusic-iOS
gh run download -R chenweitian423/CyShineMusic-iOS <run_id> \
  -n CyShineMusic-unsigned-ipa -D <临时目录>
cp <临时目录>/CyShineMusic-unsigned.ipa ../dist/
cd .. && md5sum dist/CyShineMusic-unsigned.ipa     # 记下大小与 md5
gh release create -R chenweitian423/CyShineMusic-iOS ios-v<版本> \
  --title "栖弦 iOS v<版本> (build <n>) · <一句话>" --latest \
  -F - dist/CyShineMusic-unsigned.ipa <<'EOF'
...发版说明...
EOF
```

上传前建议先自解压核对（见 7.3）：主 App 与扩展的 `CFBundleShortVersionString`
**和** `CFBundleVersion` 都必须一致、扩展 id 必须是主 App id 的前缀。

---

## 12. 轮次汇总

### 第 11 轮（`2.0.3`，提交 `080edba`）：锁屏卡片 ≠ 灵动岛

**这一轮最大的价值是纠正了诊断方向。** 用户发来趣听音乐的两张截图，
其中图 2 被当成了「灵动岛长什么样」的参考 —— 但它不是。

#### 图 2 到底是什么

| 图 | 实际是什么 | 需要什么才能实现 |
|---|---|---|
| 图 1 | App 内播放页 | 纯 Flutter UI |
| 图 2 | **iOS 锁屏系统播放卡片**（Now Playing widget） | `audio_service` → `MPNowPlayingInfoCenter`。**系统自己画**，不需要 ActivityKit / Widget 扩展 / App Groups |

**判别特征**：卡片里有进度条、上一首/下一首按钮、AirPlay 路由图标
⇒ 这是 `MPNowPlayingInfoCenter`。Live Activity 的锁屏卡片不长这样。

这与第 10 轮的发现完全一致：趣听 IPA 里 `ActivityKit`/`DynamicIsland`
符号**各 0 次** —— 它没做灵动岛，它给的是系统卡片。

**用户确认的两个事实**（决定了这一轮做什么）：
1. **锁屏上完全没有卡片** ⇒ 锁屏链路也是坏的，此前从未验证过
2. **通知授权弹窗出现了、点了「允许」** ⇒ 第 10 轮的死锁修复生效

#### bug 1：锁屏封面必须是本地文件

`audio_service-0.18.19` 的 darwin 实现，`AudioServicePlugin.m` 的 `setMediaItem`：

```objc
NSString* artUri = mediaItem[@"artUri"];
artwork = nil;
if (![artUri isEqual: [NSNull null]]) {
    NSString* artCacheFilePath = extras[@"artCacheFile"];   // ← 只认本地路径
    UIImage* artImage = [UIImage imageWithContentsOfFile:artCacheFilePath];
    if (artImage != nil) { artwork = [[MPMediaItemArtwork alloc] initWithImage:artImage]; }
}
```

**只要 `extras['artCacheFile']` 不存在，`artwork` 就是 nil，不报任何错。**
而我们此前的封面优先级是「内嵌 bytes → 网络 URL」，
在线音源（绝大多数场景）走的正是网络 URL 分支 ⇒ 锁屏卡片永远没缩略图。

修法：`cacheArtwork(bytes, {fallbackUrl})` 在没有内嵌 bytes 时自己下载并落盘，
返回本地 `file://` Uri。附带：
- 校验魔数（PNG/JPEG/GIF/WebP），防止把错误页 HTML 存成封面
- 8 MB 响应上限（`consolidateHttpClientResponseBytes` 在 `package:http` 里，
  为一张封面多引一个包不值得，自己按块收集）
- 日志里 URL 去掉 query，避免把带签名的地址整条写进日志

#### bug 2：手工组装的 appex 缺 UIDeviceFamily

实测 `2.0.2` 产物：

| bundle | `UIDeviceFamily` |
|---|---|
| `Runner.app` | `[1, 2]` |
| `CyShineMusicWidget.appex` | **缺失** |

Xcode 在真正 build extension target 时会自动注入这个键；我们是
`xcrun swiftc` 手工组装 `.appex`，**没人替我们补**。
缺失时 iOS 可能直接不加载扩展 ⇒ 灵动岛 + 桌面小组件一起消失，
而主 App 一切正常、控制台也没有任何报错。

修法：Info.plist 写死 + `build_widget_extension.sh` 兜底补写 + CI 硬校验。

#### 新增诊断：`app_task.mediaSession`

```
后台音频=已声明 会话分类=playback 会话活动=独占
nowPlaying=有9项 标题=有 歌手=有 速率=1.0 封面=有
```

`nowPlaying=空⚠` / `封面=无⚠` / `后台音频=未声明⚠` 三种判据一眼可辨。
在 `AppLifecycleState.paused/resumed` 时采一次 → 日志页 `media-session` 标签。

#### 方法论：怎么判断「这是 Now Playing 还是 Live Activity」

| 现象 | 结论 |
|---|---|
| 锁屏卡片有进度条 + 上下首 + AirPlay | `MPNowPlayingInfoCenter`（Now Playing），查 `audio_service` |
| 锁屏顶部/灵动岛位置的独立卡片，无上下首 | Live Activity，查 ActivityKit + 扩展加载 |
| 桌面长按能加小组件 | 扩展已被加载 |

### 第 10 轮（`2.0.2`，提交 `d46dcb4`）：灵动岛授权死锁

**这一轮推翻了第 9 轮的结论。** 第 9 轮把「没请求通知授权」记成「高概率根因」，
实际是**逻辑上必然复现的死锁** —— 那段代码从未被执行过。

#### 死锁的精确形状

```
① iOS 17 起，通知处于 notDetermined 时
   ActivityAuthorizationInfo().areActivitiesEnabled == false
                    ↓
② Dart live_activity_service.dart:74
   if (!supported) return;          ← 不挂监听，也不调 start
                    ↓
③ CyShineLiveActivityBridge.swift（v2.0.1）把授权请求只写在 case "start" 里
                    ↓
④ start 永不被调用 → 权限永远问不到 → ① 永远为 false
```

**可观测后果**：那个通知授权弹窗**一次都没出现过**。
所以「灵动岛不显示」与「没弹通知授权」不是两个独立现象，是同一个死锁的两端。

#### 三处修法

| 位置 | 改动 | 为什么这么改 |
|---|---|---|
| `case "isSupported"` | 先调 `ensureNotificationAuthorization()` | 这是**一定会被执行**的路径。方法幂等，所以仍只问一次 |
| 同上 | 新增 `isNotificationAuthorizationPending` | 「弹窗没回答」与「用户拒绝」在 `areActivitiesEnabled` 上**都是 false**，必须自己记一份区分。前者按可用放行，后者如实回 false |
| `ensureNotificationAuthorization` 回调 | 经 `onAuthorizationResolved` → 通道方法 `authorizationResolved` 主动推 Dart | `areActivitiesEnabled` 是在**授权落地那一刻**才翻 true 的；Dart 若已拿着 false 放弃，不会自己醒过来 |
| `live_activity_service.dart` | `_ensureAvailable({bool force})` + 处理 `authorizationResolved` | 授权回调要能突破「已判定过 false」的缓存，并立即补推当前曲目 |
| `case "start"` | 真被关掉时静默 `result(false)` + 写日志，**不回灌 FlutterError** | 回灌会被 Dart 记成「推送失败」，看起来像故障 |

#### 回归守卫

`tool/verify_live_activity_auth.mjs`（已接进 CI，紧跟 `verify_preload_protocol`）。
7 项检查：授权调用在 `isSupported` 路径上 / 有区分 pending / Dart 处理回调 /
`_ensureAvailable` 有 force / 主 App 两个 plist 键 / 扩展侧 plist 键 / 共用同一份
`CyShineActivityAttributes.swift`。

**已做负向测试**（注入回归 → `exit 1` + 打印修法；还原 → `exit 0`）——
守卫本身也要被验证，否则「一直通过」可能只是它什么都没查。

#### 顺带核实、决定不动的两项

| 项 | 结论 |
|---|---|
| `NSSupportsLiveActivitiesFrequentUpdates` 键名 | **写法正确**，与 Apple 官方文档一致。网上流传的 `NSSupportsFrequentLiveActivityUpdates` 是错的，别被带偏 |
| 现有 IPA 结构 | 两侧 `NSSupportsLiveActivities`、`MinimumOSVersion=16.2`、版本号一致、`DynamicIsland` 符号 106 次 —— 本来就对 |

#### 参考对象的核查方法（可复用）

用户提供了趣听音乐的 IPA 当参考。判定它**没有**实时活动：

| 检查 | 手段 | 结果 |
|---|---|---|
| 有没有扩展 | `Payload/*.app/PlugIns/` 是否存在 `.appex` | 无 `PlugIns/` |
| 有没有链接框架 | 在主二进制里数符号字节出现次数 | `ActivityKit` / `WidgetKit` / `DynamicIsland` / `ActivityConfiguration` **各 0** |
| 有没有声明 | Info.plist 查 `NSSupportsLiveActivities` | 无 |

**DCloud uni-app 壳，连框架都没链进去。** 两条独立证据都指向「没实现」，
才能下结论 —— 只看 plist 或只看目录都可能漏（有的 App 硬编码字符串、
有的把扩展放在 `Frameworks/` 下）。

> 教训：这次「参考一个不存在的实现」反而是有价值的 ——
> 它逼着回头查自己的包，才找到真正的死锁。

### 第 9 轮（`ios-v2.0.1` / build 17）

**已完成**

| 项 | 落点 |
|---|---|
| 原生 iOS 全量实现（BASS + JSCore + 6 个 Runner 通道 + 3 个 path 插件） | 1~5 轮 |
| CI 出未签名 IPA（含 Widget Extension 独立编译与嵌入） | 第 2、7 轮 |
| 真机 3 个 bug：音源初始化超时 / 播放报 Android-only / 点状态栏不回顶 | `ios.2` / `ios.3` / `ios.4` |
| 灵动岛 + 锁屏实时活动 + 桌面小组件（Widget Extension） | 第 7 轮 |
| 原生失败回灌 App 内日志页（`cy_shine_music/native_log`） | 第 8 轮 |
| 备用图标改走资产目录（`Assets.xcassets/AppIcon*.appiconset`） | 第 8 轮 |
| iOS 独立版本号体系（`tool/ios_version.txt`） | 第 8 轮 |
| ★ 实时活动补通知授权请求 + 诊断加 机型/通知/Bundle 三项判据 | 第 9 轮 |
| 日志页放开 iOS 原生诊断（`app_logger.dart` 按平台分流） | 第 9 轮 |

**已排除（不是 bug，别再查）**

| 现象 | 结论 |
|---|---|
| 「App 里看不到灵动岛」 | 前台运行的 App 永远不显示自己的实时活动，必须回桌面/锁屏（#37） |
| 「灵动岛位置空着」 | 灵动岛是 iPhone 14 Pro 及以上的硬件，刘海屏机型只在锁屏显示（#38） |
| 「桌面搜不到小组件」 | 侧载扩展要重启一次 iPhone 才会被 PlugInKit 注册（#42）；免费签名的 wildcard App ID 本就不支持 App Extensions |
| 「桌面小组件停在引导态」 | App Groups 需付费账号，属预期降级（#29 / 22） |
| 「备用图标切换失败」 | 老路径（散装 PNG + 手写 plist）在新 Xcode/iOS 静默失效（#32），已改资产目录 |
| 「每次出包版本号都一样」 | 上游 pubspec 里的 1.0.8；iOS 已独立编号（第 11 节） |

**当前卡点（唯一）**

灵动岛真机复测 `ios-v2.0.1`。判据全部收敛到 App 内「设置 → 日志」页
`live-activity` 的一行诊断（字段含义见 6.4 节第 4 条）：

| 那行里看到 | 说明 | 下一步 |
|---|---|---|
| `通知=未询问` | 授权弹窗没弹出来 | 调 `ensureNotificationAuthorization()` 的触发点 |
| `通知=被拒绝` | 用户点了不允许 | 设置 → 栖弦 → 通知 → 允许通知 |
| `开关=false` | 用户在设置里关了实时活动 | 设置 → 栖弦 → 实时活动 |
| `扩展=缺失` | 重签工具丢了 `PlugIns/` | 换工具重新签名 |
| `Bundle=… ⚠前缀不匹配` | 重签只改了主 App 的 id | 让扩展 id 跟着主 App 一起改 |
| `机型=iPhoneNN,N(未收录型号)` 且实际是刘海屏 | 型号表没收录该机型 | 补 `dynamicIslandModels` |
| 一行全正常、`在跑的活动=1`，锁屏能看到灵动岛、顶部看不到 | 就是刘海屏硬件 | 属预期 |

**关键路径（新会话从这里开始）**

1. 读 `F:\codex项目\音乐源播放器\HANDOFF.md` 顶部「⚡ 启动包」
2. 若要动 Swift → 改完 push，`gh run watch -R chenweitian423/CyShineMusic-iOS <run_id>` 等 macOS runner
3. 出包后手动发 Release（第 11 节的命令序列），并更新 `tool/ios_version.txt`
4. 每次都要刷新 HANDOFF 顶部快照 + 追加当日 `.workbuddy/memory/` 日志
