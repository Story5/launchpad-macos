#!/bin/bash
# 用 Developer ID Application 证书重签发布产物（公证前的必备一步）
#
# xcodebuild 默认产出的是 ad-hoc 签名（Signature=adhoc / TeamIdentifier=not set），
# 那种签名过不了 Gatekeeper：别人下载后一定会看到「Apple 无法验证…是否包含恶意软件」。
# 公证要求「Developer ID Application 证书 + Hardened Runtime（--options runtime）+ 时间戳」。
#
# 用法：
#   ./scripts/sign_release.sh [.app 路径]
#   默认路径：.build/Build/Products/Release/LaunchPad.app
#
# 需要的证书：钥匙串里必须装有 "Developer ID Application: ..." 证书
# （没有的话先用 scripts/notary_setup.sh 里的说明去 developer.apple.com 申请）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/Build/Products/Release/LaunchPad.app}"
ENT="$ROOT/scripts/entitlements.plist"

[ -d "$APP" ] || { echo "找不到产物：$APP" >&2; exit 1; }
[ -f "$ENT" ] || { echo "找不到 entitlements：$ENT" >&2; exit 1; }

# 签名身份：优先用环境变量，其次自动取钥匙串里第一个 Developer ID Application
if [ -z "${SIGN_IDENTITY:-}" ]; then
  # 末尾的 || true 不能少：pipefail 下 grep 没匹配会让整条命令替换返回 1，
  # 赋值语句的退出码就是它，set -e 会当场把脚本杀掉，连错误提示都来不及打印
  SIGN_IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo "钥匙串里没有 Developer ID Application 证书。请先申请并安装："
  echo "  https://developer.apple.com/account/resources/certificates/add  (选 Developer ID Application)"
  exit 1
fi
echo "==> 签名身份：${SIGN_IDENTITY}"

# 清掉扩展属性：构建过程会在产物上留下 com.apple.provenance 等属性，
# 带着它们签名容易报「资源已被修改」，也会让校验不过。
xattr -cr "$APP"

# --options runtime  = 开启 Hardened Runtime（公证硬性要求）
# --timestamp        = 打安全时间戳，证书过期后已签的包依然有效
# 不用 --deep        ：包内只有主可执行一个 Mach-O，--deep 会掩盖嵌套签名问题
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  --entitlements "$ENT" \
  "$APP"

codesign --verify --strict --verbose=2 "$APP"
echo "==> 签名完成："
codesign -dv "$APP" 2>&1 | grep -E "^Identifier|TeamIdentifier|Signature|Runtime" | sed 's/^/    /'
