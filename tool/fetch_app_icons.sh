#!/usr/bin/env bash
# 生成 iOS 备用图标。CI 与本地都需要在 pod install / build 之前跑一次。
# 真正的实现在 fetch_app_icons.py（只用标准库，不依赖 Pillow）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "[error] 找不到 python3 / python，无法生成 iOS 备用图标。" >&2
  echo "        备用图标缺失时 setAlternateIconName 会失败（其它功能不受影响）。" >&2
  exit 1
fi

exec "$PY" "$ROOT/tool/fetch_app_icons.py"
