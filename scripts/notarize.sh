#!/bin/bash
# 打 dmg → 用 Developer ID 签名 → 提交苹果公证 → 把票据装订（staple）进 dmg
#
# 做完这一步，别人下载 dmg 双击时不再出现「Apple 无法验证…是否包含恶意软件」。
#
# 用法：
#   ./scripts/notarize.sh                     # 完整流程：打 dmg + 签名 + 公证 + 装订
#   ./scripts/notarize.sh dist/xxx.dmg        # 只公证已有的 dmg（不再重新打包）
#
# 前置条件：
#   1) 里面的 .app 已经用 Developer ID 签过名（./scripts/sign_release.sh）
#      —— 公证会检查包内每一个可执行，ad-hoc 签名会被直接拒
#   2) 公证凭据，二选一（写在 scripts/notary.conf，该文件不入库）：
#        NOTARY_PROFILE=LP_NOTARY                 # 由 notary_setup.sh 存进钥匙串的凭据名
#        或 API_KEY=/path/AuthKey_XXXX.p8  API_KEY_ID=XXXXXXXXXX  API_ISSUER=<uuid>
#   3) 联网（公证要连苹果服务器，通常 1~5 分钟）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 读本地配置（不入库）。环境变量优先，所以命令行上临时覆盖也生效。
CONF="$ROOT/scripts/notary.conf"
if [ -f "$CONF" ]; then set -a; # shellcheck disable=SC1090
  . "$CONF"; set +a; fi

DMG_ARG="${1:-}"

if [ -n "$DMG_ARG" ]; then
  DMG="$DMG_ARG"
  [ -f "$DMG" ] || { echo "找不到 dmg：$DMG" >&2; exit 1; }
else
  # 先签名：dmg 里的 app 必须是 Developer ID + Hardened Runtime，否则公证必失败
  "$ROOT/scripts/sign_release.sh"
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$ROOT/.build/Build/Products/Release/LaunchPad.app/Contents/Info.plist")
  "$ROOT/scripts/make_dmg.sh"
  DMG="$ROOT/dist/LaunchPad-${VERSION}-arm64.dmg"
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
  # || true 同上：grep 没匹配时不能让 set -e + pipefail 把脚本静默杀掉
  SIGN_IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)
fi
[ -n "$SIGN_IDENTITY" ] || { echo "缺少 Developer ID Application 证书" >&2; exit 1; }

# make_dmg.sh 给 dmg 打的是 ad-hoc 签名，这里换成 Developer ID（dmg 不需要 runtime 选项）
echo "==> 签名 dmg：${DMG}"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

# 组装公证凭据
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${API_KEY:-}" ] && [ -n "${API_KEY_ID:-}" ] && [ -n "${API_ISSUER:-}" ]; then
  NOTARY_ARGS=(--key "$API_KEY" --key-id "$API_KEY_ID" --issuer "$API_ISSUER")
else
  echo "没有公证凭据。先跑 ./scripts/notary_setup.sh 存一次（或填 scripts/notary.conf）：" >&2
  echo "  NOTARY_PROFILE=<keychain 凭据名>" >&2
  echo "  或 API_KEY=/path/AuthKey_XXX.p8 API_KEY_ID=XXXXXXXXXX API_ISSUER=<uuid>" >&2
  exit 1
fi

echo "==> 提交公证（等苹果服务器，通常 1~5 分钟）"
LOG=$(mktemp)
STATUS=0
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1 | tee "$LOG" || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  echo "==> 公证失败，拉取日志：" >&2
  ID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$LOG" | head -1)
  if [ -n "$ID" ]; then xcrun notarytool log "${NOTARY_ARGS[@]}" "$ID" 2>&1 | tail -40 >&2 || true; fi
  rm -f "$LOG"
  exit "$STATUS"
fi
rm -f "$LOG"

# 装订票据：让没网、或 Gatekeeper 查不到苹果服务器时也能通过验证
echo "==> 装订票据"
xcrun stapler staple "$DMG"
# app 自己也装订一份：从 dmg 拖到 /Applications 后单独校验它也有效
APP="$ROOT/.build/Build/Products/Release/LaunchPad.app"
[ -d "$APP" ] && xcrun stapler staple "$APP" >/dev/null 2>&1 || true

echo "==> 校验"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | tail -3
echo "==> 完成（可直接分发）：$DMG"
