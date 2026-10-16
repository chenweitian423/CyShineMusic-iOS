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
| 换图标 | `activity-alias` 无提示切换 | ⚠️ `setAlternateIconName`，图标须预打包 + Info.plist 声明，**切换会弹系统提示** |
| 媒体库扫描 | `MediaScannerConnection` | ❌ 无等价机制（`media_scan.scan` 直接返回 true） |
| 主 App 驱动桌面卡片 | `AppWidget` RemoteViews | ❌ WidgetKit 跑在独立进程，只能经 App Group 共享数据 |
| 主动退到后台 | `moveTaskToBack` | ❌ iOS 不允许 |
| 后台常驻 | 前台服务 | ⚠️ 仅 `UIBackgroundModes: audio`（已在 Info.plist 配好） |

---

## 6. 已完成 / 未完成

### 6.1 已完成（本轮）

| 项 | 文件 |
|---|---|
| iOS 工程生成 + Bundle ID 改为 `com.cyshine.music` | `ios/` |
| Info.plist：后台音频、文件共享、备用图标声明、ATS、文档类型 | `ios/Runner/Info.plist` |
| AppDelegate / SceneDelegate：注册 Runner 插件 + 外部音频回调 | `ios/Runner/AppDelegate.swift`、`SceneDelegate.swift` |
| Runner 6 通道 iOS 实现 | `ios/Runner/CyShineNativePlugin.swift` |
| bass_player iOS：通道全方法 + 事件流 + biquad 均衡器 + BASS 同步点 | `packages/bass_player/ios/` |
| music_source_runtime iOS：双通道 + 8 native 函数 + JSCore + 定时器 | `packages/music_source_runtime/ios/` |
| music_home_widget iOS：通道 + App Group 写入 + WidgetCenter 刷新 | `packages/music_home_widget/ios/` |
| 加密层（md5/base64/AES/RSA + DER 解析） | `Classes/MusicSourceCrypto.swift` |
| BASS 二进制与头文件拉取脚本 | `tool/fetch_bass_ios.sh` |
| 备用图标生成（纯标准库 PNG 缩放） | `tool/fetch_app_icons.{sh,py}` |
| Xcode 工程接入脚本（幂等） | `tool/patch_xcodeproj.py` |
| CI：macOS 出未签名 IPA | `.github/workflows/ios-build.yml` |
| Dart 侧修正 3 处 | 见 6.2 |

### 6.2 Dart 侧改动（全部）

| 文件 | 改动 | 原因 |
|---|---|---|
| `lib/app.dart` | 新增 `_supportsPlatformDynamicColor` + `_platformDynamicColorBuilder`；`_corePaletteFuture` 加平台守卫与 onError | `dynamic_color` pub.dev 平台声明**没有 ios**，直接调用会抛 MissingPluginException |
| `lib/app.dart` | 补 `import 'package:flutter/foundation.dart';` | `kIsWeb` / `defaultTargetPlatform` 需要 |
| `lib/core/services/app_icon_service.dart` | `supportsCustomAppIcons` 放开 iOS | 走 `setAlternateIconName` |
| `lib/core/services/storage_browser_service.dart` | `isSupported` 放开 iOS | 沙盒目录仍可浏览 |

`dart analyze lib packages` 结果：**1 issue**，是上游既有的 `onReorder` 弃用提示，与本次改动无关。

### 6.3 未完成（下一步）

| 优先级 | 事项 | 说明 |
|---|---|---|
| P0 | **首次 macOS 编译修错** | 本机是 Windows，Swift 代码无法预先编译。大概率有若干编译错误要修（类型映射、API 可用性）。这是唯一还没验证过的一环 |
| P0 | 放开 `music_home_widget_service.dart:44` 的平台守卫 | 否则 iOS 小组件永远收不到数据 |
| P1 | iOS 写 mp3 标签 | 现在对非 ISO-BMFF 格式**明确报错**（不写坏文件）。方案：引入 `pod 'ID3TagEditor', '~> 5.5'`（纯 Swift，支持 ID3 读写 + 内嵌图）或 TagLib |
| P1 | ISO-BMFF（m4a）标签写入 | `CyShineNativeTaggerChannel.writeTags` 里留了分支，需接 `AVAssetExportSession` 元数据重写 |
| P2 | WidgetKit 卡片 UI | 现在只做了 App Group 数据桥；缺 `ios/CyShineMusicWidget/` target 与 SwiftUI 视图 |
| P2 | App Group entitlement | `MusicHomeWidgetPlugin.appGroupIdentifier = "group.com.cyshine.music"`，需要在 Xcode 给 Runner 与 Widget target 都配 App Groups capability（本机无法生成 entitlements 文件） |
| P2 | `audio_intent` 的 `openAudio` | 现在用 `UIActivityViewController`（分享面板）；Android 是 `ACTION_VIEW` 选播放器，iOS 只能这样 |
| P3 | 本地曲库的目录授权 UI | 原生已提供 `addRoot`/`removeRoot`（bookmark 持久化），但 Dart 侧的 `storage_folder_picker_sheet` 还没有 iOS 分支去调它 |

---

## 7. 验收命令与期望值

| 命令 | 期望 |
|---|---|
| `bash tool/fetch_bass_ios.sh` | 输出 6 个 `Frameworks/*.xcframework` + 6 个头文件；无 `[warn] 缺少头文件` |
| `bash tool/fetch_app_icons.sh` | `共生成 15 个文件` |
| `python3 tool/patch_xcodeproj.py` | 首次输出 4 行 `[ok] ... xN`；重复执行输出 `[skip]` |
| `dart analyze lib packages` | 1 issue（上游既有的 onReorder 弃用） |
| `diff android/app/src/main/assets/music_source_preload.js packages/music_source_runtime/ios/Resources/music_source_preload.js` | 无输出 |
| `cd ios && pod install` | 3 个本地 pod 全部 `Installing bass_player / music_source_runtime / music_home_widget`；无「未找到 BASS iOS 二进制」 |
| `flutter build ios --release --no-codesign` | `build/ios/iphoneos/Runner.app` 存在 |
| 真机首启 | 能进首页；能导入音源；`设置 → 关于` 里引擎版本显示 `2.4.x.y` + `builtin-biquad` |

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

---

## 9. 与上游同步的策略

- 只在 `main` 的 tag 上做 rebase，不追每日提交。
- 冲突面刻意收窄到：`lib/app.dart`（1 处）、`app_icon_service.dart`（1 处）、
  `storage_browser_service.dart`（1 处）、3 个 `pubspec.yaml`（各加 2 行）、以及新增的 `ios/` 与
  `packages/*/ios/` 目录。
- `ios/` 整体是上游没有的，rebase 时不会被触碰。
- 若上游改了原生通道契约，优先改 `packages/*/ios/` 去适配，**不要改 Dart**——否则冲突面会扩散。
