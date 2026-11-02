#!/bin/bash
# 一次性准备公证所需的凭据（存进钥匙串 / 写成本地配置）
#
# 方式 A：Apple ID + app 专用密码（最简单）
#   1. 在 https://appleid.apple.com 的「App 专用密码」里生成一个专用密码
#   2. 跑：
#        ./scripts/notary_setup.sh --apple-id you@example.com --team-id XXXXXXXXXX
#      会提示输入刚生成的专用密码，然后存进钥匙串（profile 名默认 LP_NOTARY）
#
# 方式 B：App Store Connect API key（CI 更稳，不会因账号改密码失效）
#   1. https://appstoreconnect.apple.com/access/api → 生成密钥（.p8，只有一次下载机会）
#   2. 跑：
#        ./scripts/notary_setup.sh --api-key ~/AuthKey_XXXX.p8 --key-id XXXXXXXXXX --issuer <uuid>
#      会写进 scripts/notary.conf（chmod 600，已 gitignore）
#
# 另外：「Developer ID Application」证书需要手动申请一次（Xcode 不会自动帮你建）：
#   https://developer.apple.com/account/resources/certificates/add  →  选 Developer ID Application
#   上传 CSR（可用 openssl 生成，或用「钥匙串访问 → 证书助理 → 从证书颁发机构请求证书」）
#   下载 .cer 双击装进登录钥匙串；若用 openssl 生成的私钥，需要合成 .p12 再导入：
#     openssl x509 -inform DER -in developerID_application.cer -out devid.pem
#     openssl pkcs12 -export -inkey DeveloperID.key -in devid.pem -out devid.p12
#     security import devid.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="LP_NOTARY"
APPLE_ID=""; TEAM_ID=""; API_KEY=""; KEY_ID=""; ISSUER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apple-id) APPLE_ID="$2"; shift 2 ;;
    --team-id)  TEAM_ID="$2"; shift 2 ;;
    --profile)  PROFILE="$2"; shift 2 ;;
    --api-key)  API_KEY="$2"; shift 2 ;;
    --key-id)   KEY_ID="$2"; shift 2 ;;
    --issuer)   ISSUER="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

if [ -n "$API_KEY" ]; then
  [ -f "$API_KEY" ] || { echo "找不到 .p8：$API_KEY" >&2; exit 1; }
  [ -n "$KEY_ID" ] && [ -n "$ISSUER" ] || { echo "用 --api-key 时必须同时给 --key-id 和 --issuer" >&2; exit 1; }
  CONF="$ROOT/scripts/notary.conf"
  cat > "$CONF" <<EOF
# 公证凭据（App Store Connect API key）。本文件不入库，权限 600。
API_KEY=$API_KEY
API_KEY_ID=$KEY_ID
API_ISSUER=$ISSUER
EOF
  chmod 600 "$CONF"
  echo "==> 已写入 $CONF"
  grep -qxF 'scripts/notary.conf' "$ROOT/.gitignore" 2>/dev/null || echo 'scripts/notary.conf' >> "$ROOT/.gitignore"
  exit 0
fi

[ -n "$APPLE_ID" ] || { echo "用法：$0 --apple-id <Apple ID> --team-id <Team ID>" >&2; exit 1; }
[ -n "$TEAM_ID" ]  || { echo "缺 --team-id（在 https://developer.apple.com/account 的 Membership 里看）" >&2; exit 1; }

printf 'App 专用密码（appleid.apple.com 生成，输入不回显）：'
read -rs PASSWORD
echo
[ -n "$PASSWORD" ] || { echo "密码为空" >&2; exit 1; }

xcrun notarytool store-credentials "$PROFILE" \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$PASSWORD"

CONF="$ROOT/scripts/notary.conf"
if [ -f "$CONF" ]; then
  grep -q "^NOTARY_PROFILE=" "$CONF" \
    && sed -i '' "s|^NOTARY_PROFILE=.*|NOTARY_PROFILE=$PROFILE|" "$CONF" \
    || printf 'NOTARY_PROFILE=%s\n' "$PROFILE" >> "$CONF"
else
  printf 'NOTARY_PROFILE=%s\n' "$PROFILE" > "$CONF"
  chmod 600 "$CONF"
fi
grep -qxF 'scripts/notary.conf' "$ROOT/.gitignore" 2>/dev/null || echo 'scripts/notary.conf' >> "$ROOT/.gitignore"

echo "==> 凭据已存为钥匙串 profile「$PROFILE」，并写入 $CONF"
echo "    之后直接跑：./scripts/build.sh Release --notarize"
