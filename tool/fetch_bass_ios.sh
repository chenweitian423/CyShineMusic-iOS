#!/usr/bin/env bash
# 下载 BASS iOS xcframework 与头文件，填充 packages/bass_player/ios/{Frameworks,CHeaders}。
#
# 为什么在构建时下载而不是入库：
#   BASS 的二进制仅允许在授权范围内再分发。仓库里不放二进制，构建时从官方站点取，
#   使用者需自行确认自己的 BASS 授权状态（自用/非商用免费，商用需购买授权）。
#
# 用法：
#   bash tool/fetch_bass_ios.sh            # 下载到 packages/bass_player/ios/
#   BASS_DIR=/tmp/bass bash tool/...       # 指定输出目录
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BASS_DIR:-$ROOT/packages/bass_player/ios}"
FW="$OUT/Frameworks"
HD="$OUT/Classes/CHeaders"
BASE="https://www.un4seen.com/files"

# 核心库 + iOS 上需要显式引入的解码器。
# 说明：ALAC / AAC 在 Apple 平台由 BASS 核心走系统解码器，无需独立 alac 附加库；
#       HTTPS 在 Apple 平台由 BASS 内置安全传输处理，无需 bass_ssl。
PKGS=(
  bass24-ios          # 核心
  bassflac24-ios      # FLAC
  bassape24-ios       # Monkey's Audio
  bassopus24-ios      # Opus / Ogg
  basswv24-ios        # WavPack
  bassdsd24-ios       # DSD / DSF / DFF
)

mkdir -p "$FW" "$HD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for pkg in "${PKGS[@]}"; do
  echo "[fetch] $pkg.zip"
  curl -fL --retry 4 --retry-delay 2 --retry-all-errors \
    -o "$TMP/$pkg.zip" "$BASE/$pkg.zip"

  unzip -q -o "$TMP/$pkg.zip" -d "$TMP/$pkg"

  # xcframework 目录
  while IFS= read -r -d '' xcf; do
    name="$(basename "$xcf")"
    rm -rf "$FW/$name"
    cp -R "$xcf" "$FW/$name"
    echo "        -> Frameworks/$name"
  done < <(find "$TMP/$pkg" -maxdepth 2 -name '*.xcframework' -print0)

  # 头文件（BASS 的 xcframework 内不含 Headers，头文件在 zip 根目录）
  while IFS= read -r -d '' h; do
    cp -f "$h" "$HD/$(basename "$h")"
  done < <(find "$TMP/$pkg" -maxdepth 2 -name '*.h' -print0)
done

echo
echo "[ok] Frameworks:"
ls -1 "$FW" | sed 's/^/       /'
echo "[ok] Headers:"
ls -1 "$HD" | sed 's/^/       /'

# CBassShim.h 引用的头文件必须齐全，缺了会直接编译失败，这里提前报出来。
for need in bass.h bassflac.h bassape.h bassopus.h basswv.h bassdsd.h; do
  [ -f "$HD/$need" ] || echo "[warn] 缺少头文件 $need（Shim 引用它，编译会失败）"
done

echo
echo "[done] 现在可以执行: cd <项目根> && flutter pub get && (cd ios && pod install)"
