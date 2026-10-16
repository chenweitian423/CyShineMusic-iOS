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

`recon/IOS-PORT-INTERNALS.md` 里有完整的「已完成 / 未完成」清单。简要：

- ✅ 编译链路齐备（三个插件都已声明 iOS 平台并有真实实现，不是空壳）
- ✅ 音频播放、音源解析、歌词、歌单、搜索、主题、WebDAV 同步：Dart 层原样复用
- ⚠️ 首次在 macOS 上编译大概率需要修几个 Swift 编译错误（本地是 Windows，无法预先编译验证）
- ⚠️ iOS 写 mp3 标签未实现（会明确报错，不会写坏文件）；FLAC 与 m4a 可用
- ⚠️ WidgetKit 桌面小组件只做了数据桥，卡片 UI 未做
