# CyShineMusic iOS 构建说明

> 本文只讲「怎么把它装出来」。机制原理、验收判据、踩坑记录在
> `recon/IOS-PORT-INTERNALS.md`，跟出包无关。

---

## 1. 补丁放哪

以下全部是相对**项目根**（本文件所在目录的上一级）的路径。

| 路径 | 作用 | 必需 |
|---|---|---|
| `ios/` | Flutter 生成的 iOS 工程；已改好 Info.plist（后台播放 / 文件共享 / 备用图标 / ATS）、AppDelegate、SceneDelegate | 是 |
| `ios/Runner/CyShineNativePlugin.swift` | app_icon / media_scan / storage_browser / audio_intent / native_tagger / app_task 六个通道的 iOS 实现 | 是 |
| `ios/Runner/Icons/` | 5 套备用图标 × 3 档尺寸；**必须保持存在**，Info.plist 里声明了它们 | 是 |
| `packages/bass_player/ios/` | BASS 播放引擎的 iOS 实现（podspec + Swift + biquad 均衡器 C 代码 + 头文件 shim） | 是 |
| `packages/music_source_runtime/ios/` | 音源运行时的 iOS 实现（podspec + Swift + `Resources/music_source_preload.js`） | 是 |
| `packages/music_home_widget/ios/` | 桌面卡片桥（podspec + Swift，写 App Group） | 是 |
| `tool/fetch_bass_ios.sh` | 构建前下载 BASS iOS 二进制到 `packages/bass_player/ios/Frameworks/` | 是 |
| `tool/fetch_app_icons.sh` + `tool/fetch_app_icons.py` | 从 `assets/app_icons/*.png` 生成 `ios/Runner/Icons/` | 是 |
| `tool/patch_xcodeproj.py` | 把新增的 Swift 文件与 Icons 目录接进 `project.pbxproj`（幂等） | 初次需要 |
| `tool/verify_preload_protocol.mjs` | 用 `node:vm` 验证 `preload.js` 的协议与**执行顺序**（CI 已接入） | 建议每次改 preload 后跑 |
| `.github/workflows/ios-build.yml` | macOS runner 上编译并产出未签名 IPA | 可选 |

三个 `packages/*/pubspec.yaml` 与 `lib/app.dart`、`lib/core/services/app_icon_service.dart`、
`lib/core/services/storage_browser_service.dart` 有少量改动，已在仓库里，无需手工操作。

---

## 2. 注意事项

| 不做会怎样 | 必须做的事 |
|---|---|
| `pod install` 直接报「未找到 BASS iOS 二进制」 | 构建前先跑 `bash tool/fetch_bass_ios.sh`（需要能访问 `un4seen.com`） |
| `setAlternateIconName` 失败 / 找不到图标 | 构建前先跑 `bash tool/fetch_app_icons.sh`；且 `ios/Runner/Icons/` 不能被删 |
| `flutter build ios` 报找不到 `CyShineNativePlugin.swift` | 先跑 `python3 tool/patch_xcodeproj.py`（只在第一次或从上游 rebase 后需要） |
| 音源在 iOS 与 Android 上行为不一致 | 改 `android/app/src/main/assets/music_source_preload.js` 后，必须同步 `packages/music_source_runtime/ios/Resources/music_source_preload.js`（CI 有 md5 校验会拦） |
| 编译不过 | Flutter 必须 **≥ 3.41.0**（本项目用 3.47.7 验证）；Xcode 15+；必须用 `Runner.xcworkspace` 而不是 `Runner.xcodeproj` |
| 在国内拉不动依赖 | 构建前设 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` 与 `PUB_HOSTED_URL=https://pub.flutter-io.cn` |
| 未签名 IPA 装不上 | 未签名 IPA 必须用 AltStore / SideStore / 自签工具安装；免费证书 **7 天**有效，过期要重签 |
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
flutter build ios --release --no-codesign
# 产物：build/ios/iphoneos/Runner.app
```

### 3.2 GitHub Actions（推荐：没有 Mac 也能出包）

```bash
git add -A
git commit -m "iOS port"
git push origin ios        # 或手动触发 workflow_dispatch

# 然后在 GitHub → Actions → iOS Build (unsigned IPA) → 下载 artifact：
#   CyShineMusic-unsigned-ipa / CyShineMusic-unsigned.ipa
```

工作流里已包含：装 Flutter（含国内镜像变量）、取 BASS、校验 preload 一致性、生成图标、
`pub get` / `analyze` / `test` / `pod install` / `build ios --no-codesign`、打包成 IPA、上传。

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
| 备用图标（5 套） | ✅ 已实现（切换有系统提示，且需放开 `app_icon_service` 的平台判断——已改） |
| 本地曲库 | ⚠️ 只能扫 App Documents + 用户授权目录（iOS 沙盒限制） |
| 音频标签读写 | ⚠️ 读全格式可用；写仅 m4a 可用，FLAC 走纯 Dart；**写 mp3 暂不支持，会明确报错而不是写坏文件** |
| 桌面小组件 | ⚠️ 数据桥已做，WidgetKit 卡片 UI 未做 |

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
| 导入音源报「音源初始化超时」 | ★ 音源运行时的三步顺序**必须是 `preload.js` → `music_source_setup(metadata)` → 音源脚本**（`globalThis.lx` 在第二步才创建）。另外 JSCore 设了 `exceptionHandler` 后异常不一定留在 `context.exception` 里，必须在 handler 里自己留一份、并把加载失败直接抛回 Dart，否则任何 JS 错误都只会表现成「超时」。详情见 `recon/IOS-PORT-INTERNALS.md` 第 8 节 #15/#16 |
| 想在没有 Mac 的情况下验证音源协议 | `node tool/verify_preload_protocol.mjs` —— 用 `node:vm` 隔离跑 preload 的协议与执行顺序，场景 B 专门复现「顺序写反 → `lx is not defined`」。已接入 CI |
| 真机出问题不知道从哪查 | 先看 app 内**「日志」页**的 `music-source` 标签：JS 异常、脚本字节数、setup 是否完成、是否在等 `inited` 都会写在那里 |
