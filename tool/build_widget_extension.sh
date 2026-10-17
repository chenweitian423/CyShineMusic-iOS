#!/usr/bin/env bash
# 编译 Widget Extension（灵动岛实时活动 + 桌面小组件）并塞进 Runner.app/PlugIns/。
#
# 为什么不用 Xcode 工程：Flutter 的 Runner.xcodeproj 是工具生成的，往里加一个
# app-extension target 要改十几处 pbxproj（新 target + 依赖 + Embed App Extensions
# phase + 一堆构建设置），一旦写错会把**主 App 的构建也弄坏**。
# 这里改成「扩展独立编译、构建完再塞进 PlugIns/」—— 正好等价于 Xcode 的
# embed 阶段做的事，而失败时最多只是没有小组件，主 App 照常出包。
#
# 用法：
#   bash tool/build_widget_extension.sh <Runner.app 路径>
# 例如：
#   bash tool/build_widget_extension.sh build/ios/iphoneos/Runner.app
#
# 可选环境变量（不传就用 Info.plist 里写死的版本）：
#   IOS_BUILD_NAME    覆盖 CFBundleShortVersionString，与主 App 的 --build-name 一致
#   IOS_BUILD_NUMBER  覆盖 CFBundleVersion，与主 App 的 --build-number 一致
#
# 只在 macOS 上可用（需要 Xcode 的 iphoneos SDK）。
set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  echo "[error] 用法: bash tool/build_widget_extension.sh <Runner.app 路径>" >&2
  exit 2
fi
if [ ! -d "$APP_PATH" ]; then
  echo "[error] 找不到 $APP_PATH —— 请先跑 flutter build ios --release --no-codesign" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/ios/CyShineMusicWidget"
BUILD="$ROOT/build/CyShineMusicWidget"

NAME="CyShineMusicWidget"
# 实时活动（ActivityKit）的最低版本，与 patch_xcodeproj.py 保持一致。
# 16.2 而不是 16.1：Activity.request / update / end / ActivityContent 都是 16.2 起才有。
MIN_IOS="16.2"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "[error] 找不到 xcrun —— 这个脚本只能在 macOS 上跑。" >&2
  exit 2
fi

echo "[1/4] 检查源码"
for f in CyShineActivityAttributes.swift CyShineLiveActivityWidget.swift \
         CyShineHomeWidget.swift CyShineWidgetBundle.swift Info.plist; do
  [ -f "$SRC/$f" ] || { echo "[error] 缺少 $SRC/$f" >&2; exit 1; }
done
ls -1 "$SRC" | sed 's/^/      /'

APPEX="$BUILD/$NAME.appex"
rm -rf "$BUILD"
mkdir -p "$APPEX"

echo "[2/4] 用 iphoneos SDK 编译 ($MIN_IOS+, arm64)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos swiftc \
  -sdk "$SDK" \
  -target "arm64-apple-ios$MIN_IOS" \
  -application-extension \
  -parse-as-library \
  -O \
  -module-name "$NAME" \
  -framework SwiftUI \
  -framework WidgetKit \
  -framework ActivityKit \
  -o "$APPEX/$NAME" \
  "$SRC/CyShineActivityAttributes.swift" \
  "$SRC/CyShineLiveActivityWidget.swift" \
  "$SRC/CyShineHomeWidget.swift" \
  "$SRC/CyShineWidgetBundle.swift"

echo "[3/4] 组装 .appex"
cp "$SRC/Info.plist" "$APPEX/Info.plist"
# Xcode 通常在打包时注入这几项，这里是手工组装，显式补上：
#  - MinimumOSVersion: 系统用它判断能否加载这个扩展
#  - CFBundleSupportedPlatforms: 让设备认为这是 iOS 平台的可执行体
/usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string $MIN_IOS" "$APPEX/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $MIN_IOS" "$APPEX/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$APPEX/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" "$APPEX/Info.plist" 2>/dev/null || true

# 版本号与主 App 对齐（主 App 由 --build-name / --build-number 注入）。
# 扩展与主 App 的 CFBundleVersion 必须一致，否则 iOS 会拒绝加载扩展，
# 表现为「灵动岛怎么都不出现」而控制台只有一条很含糊的提示。
#
# ★ UIDeviceFamily：Xcode 在真正 build extension target 时会自动注入这个键，
#   但这里是手工组装 .appex，没人会替我们补。**缺失时 iOS 可能直接不加载扩展**
#   —— 桌面小组件搜不到、灵动岛不出现，而主 App 完全正常、一条报错都没有。
#   已实测过我们 2.0.2 的包里 appex 就是缺这个键。
if ! /usr/libexec/PlistBuddy -c "Print :UIDeviceFamily" "$APPEX/Info.plist" >/dev/null 2>&1; then
  echo "      (补写 UIDeviceFamily —— 缺失会导致扩展不被加载)"
fi
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" "$APPEX/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:0 integer 1" "$APPEX/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:1 integer 2" "$APPEX/Info.plist" 2>/dev/null || true

if [ -n "${IOS_BUILD_NAME:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $IOS_BUILD_NAME" "$APPEX/Info.plist"
  echo "      CFBundleShortVersionString = $IOS_BUILD_NAME"
fi
if [ -n "${IOS_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $IOS_BUILD_NUMBER" "$APPEX/Info.plist"
  echo "      CFBundleVersion = $IOS_BUILD_NUMBER"
fi

echo "[4/4] 嵌入 $APP_PATH/PlugIns/"
mkdir -p "$APP_PATH/PlugIns"
rm -rf "$APP_PATH/PlugIns/$NAME.appex"
cp -R "$APPEX" "$APP_PATH/PlugIns/"

echo
echo "[ok] 扩展已嵌入："
ls -la "$APP_PATH/PlugIns/$NAME.appex" | sed 's/^/      /'
echo
echo "[info] 二进制信息："
xcrun lipo -info "$APP_PATH/PlugIns/$NAME.appex/$NAME" | sed 's/^/      /'
echo
echo "[info] Info.plist 关键项："
for key in CFBundleIdentifier CFBundleExecutable NSExtension MinimumOSVersion UIDeviceFamily; do
  printf "      %-32s " "$key"
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP_PATH/PlugIns/$NAME.appex/Info.plist" 2>/dev/null | tr '\n' ' ' || echo "(缺失)"
  echo
done
/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" \
  "$APP_PATH/PlugIns/$NAME.appex/Info.plist" 2>/dev/null | sed 's/^/      NSExtensionPointIdentifier  /'
echo
echo "[done] 现在打出的 IPA 会带上灵动岛实时活动与桌面小组件"
