# CyShineMusic iOS 构建说明

> 本文只讲「怎么把它装出来」。机制原理、验收判据、踩坑记录在
> `recon/IOS-PORT-INTERNALS.md`，跟出包无关。

---

## 1. 补丁放哪

以下全部是相对**项目根**（本文件所在目录的上一级）的路径。

| 路径 | 作用 | 必需 |
|---|---|---|
| `ios/` | Flutter 生成的 iOS 工程；已改好 Info.plist（后台播放 / 文件共享 / ATS）、AppDelegate、SceneDelegate | 是 |
| `ios/Runner/CyShineNativePlugin.swift` | app_icon / media_scan / storage_browser / audio_intent / native_tagger / app_task 六个通道的 iOS 实现 | 是 |
| `ios/Runner/CyShineNativeLog.swift` | 原生 → Dart 的日志桥（通道 `cy_shine_music/native_log`）。**别删**：删掉后原生失败在 App 内「日志」页就看不见了 | 是 |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/` | 主图标（15 个尺寸，由脚本生成） | 是 |
| `ios/Runner/Assets.xcassets/AppIcon<Name>.appiconset/` | **5 套备用图标**（资产目录形态，`setAlternateIconName` 靠它）。目录名 `AppIconMidnight / AppIconSky / AppIconLavender / AppIconMint / AppIconPeach` 必须逐字一致，否则系统找不到图标 | 是 |
| `ios/Runner/Icons/` | 同样的 5 套备用图标，散装 PNG 形态（兜底副本） | 否 |
| `packages/bass_player/ios/` | BASS 播放引擎的 iOS 实现（podspec + Swift + biquad 均衡器 C 代码 + 头文件 shim） | 是 |
| `packages/music_source_runtime/ios/` | 音源运行时的 iOS 实现（podspec + Swift + `Resources/music_source_preload.js`） | 是 |
| `packages/music_home_widget/ios/` | 桌面卡片桥（podspec + Swift，写 App Group） | 是 |
| `tool/fetch_bass_ios.sh` | 构建前下载 BASS iOS 二进制到 `packages/bass_player/ios/Frameworks/` | 是 |
| `tool/fetch_app_icons.sh` + `tool/fetch_app_icons.py` | 从 `assets/app_icons/classic.png` 生成主图标（15 个尺寸）+ 5 套备用图标集 + 散装兜底副本；只用标准库 | 是 |
| `tool/ios_version.txt` | **iOS 版本号的唯一来源**（与上游 Android 的版本解耦）。发版就是改这个文件 | 是 |
| `ios/CyShineMusicWidget/` | Widget Extension 源码：灵动岛 + 锁屏卡片 + 桌面小组件；`CyShineActivityAttributes.swift` 会被主 App 与扩展**同时**编译 | 是 |
| `ios/Runner/CyShineLiveActivityBridge.swift` | 实时活动的主 App 侧桥接（ActivityKit + App Group 写入 + 深链回调） | 是 |
| `tool/build_widget_extension.sh` | 用 `xcrun swiftc` 独立编译扩展并塞进 `Runner.app/PlugIns/`（不进 `Runner.xcodeproj`） | 是 |
| `tool/patch_xcodeproj.py` | 把新增的 Swift 文件接进 `project.pbxproj`、对齐部署目标、写入备用图标的资产目录构建设置（幂等，按文件名去重） | 初次需要 |
| `tool/verify_preload_protocol.mjs` | 用 `node:vm` 验证 `preload.js` 的协议与**执行顺序**（CI 已接入） | 建议每次改 preload 后跑 |
| `.github/workflows/ios-build.yml` | macOS runner 上编译并产出未签名 IPA | 可选 |

三个 `packages/*/pubspec.yaml` 与 `lib/app.dart`、`lib/core/services/app_icon_service.dart`、
`lib/core/services/storage_browser_service.dart` 有少量改动，已在仓库里，无需手工操作。

---

## 2. 注意事项

| 不跑会怎样 | 必须做的事 |
|---|---|
| `pod install` 直接报「未找到 BASS iOS 二进制」 | 构建前先跑 `bash tool/fetch_bass_ios.sh`（需要能访问 `un4seen.com`） |
| 图标还是 Flutter 默认图 | 构建前先跑 `bash tool/fetch_app_icons.sh` |
| 设置里点「换图标」失败 | 备用图标现在走**资产目录**：`ios/Runner/Assets.xcassets/AppIcon<Name>.appiconset/` 必须存在，且 `tool/patch_xcodeproj.py` 写入的两条构建设置（`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` / `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`）不能被删。**不要**再往 `Info.plist` 手工加 `CFBundleIcons` —— 手工声明图标键在新 Xcode / 新 iOS 上会静默失效 |
| 换了图标还是失败、且不知道为什么 | 打开 App 内**「日志」页**筛 `app-icon` 标签：会打印 `supportsAlternateIcons` 是否为 false、每个候选名各自的错误 domain#code |
| 改了 `assets/app_icons/classic.png` 但图标没变 | 手动跑一次 `bash tool/fetch_app_icons.sh`（生成物已入库） |
| `flutter build ios` 报找不到 `CyShineNativePlugin.swift` | 先跑 `python3 tool/patch_xcodeproj.py`（只在第一次或从上游 rebase 后需要） |
| 音源在 iOS 与 Android 上行为不一致 | 改 `android/app/src/main/assets/music_source_preload.js` 后，必须同步 `packages/music_source_runtime/ios/Resources/music_source_preload.js`（CI 有 md5 校验会拦） |
| 每次出包版本号都一样 | 改 `tool/ios_version.txt`。`CFBundleVersion` 由 CI 的 run number 自动递增，不用管 |
| 编译不过 | Flutter 必须 **≥ 3.41.0**（本项目用 3.47.7 验证）；Xcode 15+；必须用 `Runner.xcworkspace` 而不是 `Runner.xcodeproj` |
| 在国内拉不动依赖 | 构建前设 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` 与 `PUB_HOSTED_URL=https://pub.flutter-io.cn` |
| 未签名 IPA 装不上 | 未签名 IPA 必须用 AltStore / SideStore / 自签工具安装；免费证书 **7 天**有效，过期要重签 |
| 装不上 / 灵动岛不出现 | 设备必须是 **iOS 16.2+**（`Activity.request/update/end` 是 16.2 才有的，见下方踩坑表） |
| 灵动岛不出现 | ① 装好后去 **设置 → 栖弦 → 实时活动** 打开开关（打开后不用重启 App）；② 锁屏也要显示的话，再去 **设置 → 面容 ID 与密码 → 锁定时允许访问 → 实时活动** 打开；③ 看 App 内**「日志」页**的 `live-activity` 标签，会打印开关状态 / 在跑的活动数 / **扩展是否在 `PlugIns` 里** / 发起失败的具体原因 |
| 按上面做了还是看不到灵动岛 | ★★ **前台运行的 App 永远不会显示自己的实时活动** —— 这是 iOS 的设计，App 在屏幕上时它自己就占着显示区域。**必须按 Home 回到桌面或锁屏**再看。在 App 里截图是看不到的 |
| 机型根本没有灵动岛 | **灵动岛是 iPhone 14 Pro 及以上的硬件**。刘海屏机型（iPhone 13 及更早、14/15/16 非 Pro）实时活动**只能出现在锁屏与通知中心**，灵动岛位置永远是空的。这不是实现问题 |
| 屏幕顶部**长期没有**「栖弦」字样 | 侧载工具重签时如果把 `PlugIns/CyShineMusicWidget.appex` 丢掉，扩展就加载不了 —— 灵动岛与桌面小组件会一起消失。日志页的 `live-activity` 会直接写「扩展=缺失」 |
| 桌面小组件一直显示「打开 App 播放点什么」 | 小组件的数据走 **App Group `group.com.cyshine.music`**，需要付费账号的 App Groups 能力。**免费签名拿不到，属预期降级**（灵动岛不受影响）。有付费证书时给 Runner 与 Widget 两个 target 都配上该能力即可 |
| BASS 授权风险 | BASS 自用免费、**商用需自行购买授权**；本仓库刻意不携带 BASS 二进制，全部构建时下载 |
| 上架失败（必然） | 自定义音源 + 在线音乐播放无法通过 App Store 审核，只能侧载/内测 |

---

## 3. 构建命令

### 3.1 macOS 本地（真机 / 模拟器）

```bash
# 只做一次：国内镜像
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn

# 每次重新 clone 或 rebase 后
bash tool/fetch_bass_ios.sh
bash tool/fetch_app_icons.sh
python3 tool/patch_xcodeproj.py

flutter pub get
cd ios && pod install && cd ..

# 真机调试（需要 Apple 账号签名）
flutter run --release -d <你的设备名>

# 只出未签名产物
VER="$(tr -d '[:space:]' < tool/ios_version.txt)"
flutter build ios --release --no-codesign \
  --build-name="$VER" --build-number="$(date +%y%m%d%H%M)"
buf="build/ios/iphoneos/Runner.app"   # buf=产物目录
IOS_BUILD_NAME="$VER" IOS_BUILD_NUMBER="$(date +%y%m%d%H%M)" \
  bash tool/build_widget_extension.sh "$buf"
# 产物：build/ios/iphoneos/Runner.app（含 PlugIns/CyShineMusicWidget.appex）
```

`--build-name` / `IOS_BUILD_NAME` 取 `tool/ios_version.txt`；
`--build-number` / `IOS_BUILD_NUMBER` 只是给 iOS 看的内部构建号，保证单调递增即可。
**扩展与主 App 的 `CFBundleVersion` 必须一致**，否则 iOS 会拒绝加载扩展
（表现是灵动岛怎么都不出现，且不报错）。

### 3.2 GitHub Actions（推荐：没有 Mac 也能出包）

```bash
git add -A
git commit -m "iOS port"
git push origin ios        # 或手动触发 workflow_dispatch

# 然后在 GitHub → Actions → iOS Build (unsigned IPA) → 下载 artifact：
#   CyShineMusic-unsigned-ipa / CyShineMusic-unsigned.ipa
```

工作流里已包含：装 Flutter（含国内镜像变量）、取 BASS、校验 preload 一致性、生成图标、
解析 iOS 版本、`pub get` / `analyze` / `test` / `pod install` /
`build ios --no-codesign`、编译并嵌入 Widget 扩展、校验扩展与备用图标、打包成 IPA、上传。
Step summary 里会写出本次的版本号。

### 3.3 侧载安装

```text
1. 把 CyShineMusic-unsigned.ipa 传到 iPhone（AirDrop / 文件 App / 网盘）
2. 用 AltStore 或 SideStore 打开该 IPA 安装
3. 首次运行需在 设置 → 通用 → VPN与设备管理 里信任证书
4. 免费 Apple ID 的签名 7 天后失效，重新用 AltStore 刷新即可
```

---

## 4. 当前状态（构建前务必先看）

**编译链路已在 GitHub Actions（macOS runner）上完整跑通并产出未签名 IPA。**
仓库：`https://github.com/chenweitian423/CyShineMusic-iOS`，分支 `ios`。
Actions → `iOS Build (unsigned IPA)` → artifact `CyShineMusic-unsigned-ipa`。
产物约 **11.9 MB**，已核实内嵌 `bass / bassflac / bassape / bassopus / basswv / bassdsd`
与三个插件 framework，`music_source_preload.js`、15 个备用图标、Info.plist 各项均正确。

已实现的功能面：

| 能力 | 状态 |
|---|---|
| 在线检索 / 音源解析 / 播放 / 歌词 / 歌单 / 搜索 / 主题 / WebDAV 同步 | ✅ Dart 层原样复用 |
| 自定义音源（JS 运行时 + 8 个 native 函数） | ✅ 已实现（JavaScriptCore） |
| 音频播放（BASS，含自研 biquad 均衡器） | ✅ 已实现 |
| 后台播放 / 锁屏控制 | ✅ Info.plist 已配 `UIBackgroundModes: audio` |
| 外部音频文件导入 | ✅ 已实现 |
| 备用图标（5 套） | ⚠️ 已实现但**真机切换仍失败**，本轮改走资产目录 + 加诊断，待复测 |
| 本地曲库 | ⚠️ 只能扫 App Documents + 用户授权目录（iOS 沙盒限制） |
| 音频标签读写 | ⚠️ 读全格式可用；写仅 m4a 可用，FLAC 走纯 Dart；**写 mp3 暂不支持，会明确报错而不是写坏文件** |
| 灵动岛 / 锁屏实时活动 | ⚠️ 已实现但**真机不显示**，本轮加诊断 + 改用资产目录路径/补扩展 plist，待复测 |
| 桌面小组件（small / medium） | ⚠️ UI 已做；真实数据需要 App Groups 能力（免费签名拿不到 → 停在引导态） |
| 点状态栏回顶 | ✅ 已实现（框架实现被外壳 Scaffold 挡住，见下方踩坑表） |

**版本号**：iOS 从 `2.0.0` 起独立编号（`tool/ios_version.txt`），
不再跟着上游 Android 的 `1.0.8`；`CFBundleVersion` 用 CI run number 自动递增。

**还没做的验证：音乐播放链路。** 真机已装上并跑起来（能进首页），
第一个真机 bug（导入音源报「音源初始化超时」）已在 `v1.0.8-ios.2` 修复。
接下来要实测：检索 → 音源解析 → 播放 → 逐字歌词 → 锁屏切歌。

---

## 5. 编译时踩过的坑（改代码前先看，能省几轮 CI）

| 现象 | 原因与对策 |
|---|---|
| 链接期 34 个 `Undefined symbol: _BASS_*` | CocoaPods 的 `vendored_frameworks` 在这个组合下**不会**生成 `-framework` 链接参数。podspec 里必须显式给 `FRAMEWORK_SEARCH_PATHS = $(PODS_TARGET_SRCROOT)/Frameworks` 与 `OTHER_LDFLAGS = -framework bass -framework bassflac ...`（见 `packages/bass_player/ios/bass_player.podspec`） |
| `Method 'handle(_:result:)' must be declared public because it matches a requirement in public protocol 'FlutterPlugin'` | **不要把自己的方法命名成 `handle(_:result:)`**，Flutter 的 `FlutterPlugin` 协议里有个可选要求就叫这个名字。改名 `handleCall` |
| 一串莫名的 `Call can throw, but it is not marked with 'try'` | Swift 在 `DispatchQueue.async` 嵌套下会把「传给 throwing 闭包参数的尾随闭包」误判成非 throwing。**别写 `helper { self.throwingCall() }` 这种形式**，改成在队列闭包里直接 `do/catch`（`BassPlayerPlugin.handleCall` 就是这么写的） |
| `Cannot convert value of type 'Int' to expected argument type 'Int32'` | 字面量常量要显式声明类型：`private static let cancelledCode: Int32 = -1000` |
| `Missing argument for parameter #6` 且指向 `BASS_DSD_*` | **`BASS_DSD_StreamCreateURL/File` 比其它附加库多一个 `freq` 参数**（0 = 保持源采样率）。flac/ape/wv/opus 都是 5 个参数，别照抄 |
| `framework not found CommonCrypto` | iOS SDK 没有 `CommonCrypto.framework`，符号在 libSystem 里，Swift 直接 `import CommonCrypto` 即可。**不要**写进 podspec 的 `s.frameworks` |
| `import CBass` 报 no such module | BASS 的 xcframework **不含头文件**，必须有 `Classes/CHeaders/{CBassShim.h,module.modulemap}` + podspec 里的 `SWIFT_INCLUDE_PATHS = $(PODS_TARGET_SRCROOT)/Classes/CHeaders` |
| 备用图标在 iOS 上找不到 | 图标必须被拷贝到 **`Runner.app/` 根目录**，不能放在 `Runner.app/Icons/` 子目录里。所以 `tool/patch_xcodeproj.py` 是按**单个文件**加入 Copy Bundle Resources（不是文件夹引用）。注意 `PBXFileReference` 的 `path` 要写 `Icons/<name>`（相对 Runner group），漏了前缀会报 `Build input file cannot be found` |
| 图标带 alpha / 显示异常 | iOS app icon 不应带 alpha 通道（App Store Connect 会拒绝）。`tool/fetch_app_icons.py` 写出的 PNG 是 color type 2（无 alpha） |
| 往 `ios/Runner/Icons/` 放了别的 PNG | 该目录被 `patch_xcodeproj.py` glob 所有 `*.png` 并全部打进 app bundle。预览图之类请放 `recon/` |
| 能装包，但一用某功能就抛 `UnsupportedError: ... only` | ★ **Dart 插件层还有遗留的平台守卫**。给插件加上 iOS 平台后，务必 grep 一遍 `TargetPlatform.android` / `Platform.isAndroid` / `UnsupportedError`。真机上「搜歌播放」报 `BASS playback is available on Android only` 就是这么来的 |
| 点状态栏不回顶 / 其它 iOS 手感缺失 | ★ iOS 独有的框架分支行为，Android 上测不出来。点状态栏回顶被外壳 Scaffold 挡住（`ShellRoute` + `indexedStack` 结构下必然发生），修复见 `lib/core/ui/scroll_to_top.dart` 与 `recon/IOS-PORT-INTERNALS.md` 第 8 节 #22 |
| 导入音源报「音源初始化超时」 | ★ 音源运行时的三步顺序**必须是 `preload.js` → `music_source_setup(metadata)` → 音源脚本**（`globalThis.lx` 在第二步才创建）。另外 JSCore 设了 `exceptionHandler` 后异常不一定留在 `context.exception` 里，必须在 handler 里自己留一份、并把加载失败直接抛回 Dart，否则任何 JS 错误都只会表现成「超时」。详情见 `recon/IOS-PORT-INTERNALS.md` 第 8 节 #15/#16 |
| 想在没有 Mac 的情况下验证音源协议 | `node tool/verify_preload_protocol.mjs` —— 用 `node:vm` 隔离跑 preload 的协议与执行顺序，场景 B 专门复现「顺序写反 → `lx is not defined`」。已接入 CI |
| 真机出问题不知道从哪查 | 先看 app 内**「日志」页**的 `music-source` 标签：JS 异常、脚本字节数、setup 是否完成、是否在等 `inited` 都会写在那里 |
| 一串 `'Activity.request/update/end' is only available in iOS 16.2 or newer` | **实时活动的门槛是 16.2，不是 16.1**（16.1 只有 `Activity.activities` 与 `ActivityAuthorizationInfo`）。门槛要同时改四处：`tool/patch_xcodeproj.py` 的 `DEPLOYMENT_TARGET`、`tool/build_widget_extension.sh` 的 `MIN_IOS`、Runner 侧 `@available`/`#available`、Widget 扩展侧 `@available` |
| 链接期 `duplicate symbol`，或 `Multiple commands produce '.../Runner.app/icon_xxx.png'` | `project.pbxproj` 里同一个文件被加了**两份**条目（历史手敲的 `C7A0E0…` ID 与脚本派生的 `C7A0F0…` 不兼容）。`tool/patch_xcodeproj.py` 现在按**文件名**先清后建，重跑一次即可收敛；脚本末尾会校验「每个文件在构建阶段恰好出现 1 次」 |
| `Build input file cannot be found: 'ios/Runner/icon_xxx.png'` | 图标 `PBXFileReference` 的 `path` 要写 `Icons/<name>`（相对 Runner group）。脚本已自动修正 |
| 手工在 `Info.plist` 写 `CFBundleIcons` / `CFBundleAlternateIcons`，图标切换失败 | ★ 手工声明图标键在新 Xcode / 新 iOS 上会**静默失效**（`setAlternateIconName` 报错或 `supportsAlternateIcons` 返回 false）。必须用资产目录 + `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`，让 Xcode 生成这些键 |
| `Assets.car` 里找不到备用图标集 | 少写了 `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` —— actool 默认只编主图标，其余图标集会被整个丢掉 |
| 扩展加载不了 / 灵动岛与桌面小组件一起消失 | 扩展与主 App 的 `CFBundleVersion` 不一致，或被侧载工具重签时丢了 `PlugIns/`。`tool/build_widget_extension.sh` 会用 `IOS_BUILD_NAME`/`IOS_BUILD_NUMBER` 对齐版本；日志页 `live-activity` 会写「扩展=缺失」 |
| 原生失败在 App 内「日志」页看不到 | 原生的错误默认只进 `NSLog`，Release 包上用户看不到。必须经 `ios/Runner/CyShineNativeLog.swift` 的 `cy_shine_music/native_log` 通道回灌给 Dart 的 `AppLogger` |
| Widget Extension 编译过但系统不渲染活动 | ① 扩展的 `Info.plist` 也要有 `NSSupportsLiveActivities`；② `WidgetBundle.body` 里必须**无条件**列出实时活动 widget（不要用 `if #available` 包，各 Xcode 版本 `buildIf` 支持不一致，用扩展自身 `MinimumOSVersion` 拦版本） |
