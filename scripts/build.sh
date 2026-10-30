#!/bin/bash
# 一键构建 LaunchPad.app（产物输出到 dist/LaunchPad.app）
# 用法：./scripts/build.sh [Debug|Release]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-Release}"
DD="$ROOT/.build"

# 应用图标：缺失时自动生成（也可手动 `python3 scripts/make_icon.py` 重建）
if [ ! -f "$ROOT/LaunchPad/Resources/AppIcon.icns" ]; then
  echo "==> 生成应用图标（AppIcon.icns）"
  python3 "$ROOT/scripts/make_icon.py"
fi

echo "==> 生成 Xcode 工程"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
else
  if [ ! -d "LaunchPadReplica.xcodeproj" ]; then
    echo "缺少 xcodegen，且不存在 LaunchPadReplica.xcodeproj。请先安装：brew install xcodegen" >&2
    exit 1
  fi
fi

# 阻止 Spotlight 索引构建中间产物：否则 mds 会把 .build 里的 LaunchPad.app
# 也注册进 LaunchServices，Spotlight 就会出现多个同名 App（其中有的还没图标）
mkdir -p "$DD"
touch "$DD/.metadata_never_index"

echo "==> 编译（${CONFIG}）"
xcodebuild \
  -project LaunchPadReplica.xcodeproj \
  -scheme LaunchPad \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DD" \
  build

APP="$DD/Build/Products/$CONFIG/LaunchPad.app"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/LaunchPad.app"
cp -R "$APP" "$ROOT/dist/LaunchPad.app"

# 只让 dist 里的这份被系统识别：注销中间产物，注册交付版
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$ROOT/dist/LaunchPad.app" >/dev/null 2>&1 || true
fi

echo "==> 完成：$ROOT/dist/LaunchPad.app"
echo "    安装：cp -R \"$ROOT/dist/LaunchPad.app\" /Applications/"
echo "    运行：open \"$ROOT/dist/LaunchPad.app\"（启动后按 F4 或点菜单栏图标）"
