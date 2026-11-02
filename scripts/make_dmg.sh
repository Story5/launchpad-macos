#!/bin/bash
# 把构建产物打成 dmg（内含 LaunchPad.app + /Applications 替身，拖进去即可安装）
# 用法：./scripts/make_dmg.sh
# 依赖：先跑过 ./scripts/build.sh Release（脚本从 .build 里取产物，不依赖 dist/LaunchPad.app，
#       因为本机装过 /Applications 后那份会被构建脚本移除）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SRC="$ROOT/.build/Build/Products/Release/LaunchPad.app"
[ -d "$SRC" ] || { echo "找不到构建产物：$SRC，请先运行 ./scripts/build.sh Release" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist")
STAGE="$ROOT/.build/dmg-stage"
DMG="$ROOT/dist/LaunchPad-${VERSION}-arm64.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE/LaunchPad"
cp -R "$SRC" "$STAGE/LaunchPad/LaunchPad.app"
# /Applications 替身：用户打开 dmg 后把 App 拖到它上面就装好了
ln -sfn /Applications "$STAGE/LaunchPad/Applications"
# 快捷方式在 Finder 里才显示，命令行 ls 看不到内容属正常
mkdir -p "$ROOT/dist"
rm -f "$DMG"

echo "==> 生成 dmg（UDZO 压缩）"
hdiutil create -volname "LaunchPad ${VERSION}" \
  -srcfolder "$STAGE/LaunchPad" \
  -ov -format UDZO -imagekey zlib-level=9 \
  "$DMG" >/dev/null

# 顺手 ad-hoc 签名：与 App 一致（未公证，Gatekeeper 仍会拦，右键打开放行）
codesign --force --sign - "$DMG" 2>/dev/null || true

rm -rf "$STAGE"
echo "==> 完成：$DMG"
echo "    校验：hdiutil verify \"$DMG\""
echo "    试用：open \"$DMG\""
