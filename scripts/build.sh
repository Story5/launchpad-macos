#!/bin/bash
# 一键构建 LaunchPad.app（产物输出到 dist/LaunchPad.app）
# 用法：./scripts/build.sh [Debug|Release] [--dmg] [--notarize]
#   --dmg        顺带打发布包 dist/LaunchPad-<版本>-arm64.dmg（现在只发 dmg，不再出 zip）
#   --notarize   额外用 Developer ID 签名并提交苹果公证后装订票据（别人下载不再报警告）
#                需要先跑一次 ./scripts/notary_setup.sh 存好凭据

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-Release}"
DD="$ROOT/.build"
MAKE_DMG=0
NOTARIZE=0
for arg in "${@:2}"; do
  case "$arg" in
    --dmg) MAKE_DMG=1 ;;
    --notarize) MAKE_DMG=1; NOTARIZE=1 ;;
  esac
done

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

# 要公证的话，产物必须在「拷贝出去」之前就用 Developer ID 重签：
# 公证检查的是 dmg 里那份，而 dmg 是从 .build 打的；但同时本机 /Applications 那份
# 也会跟着一起拷贝，先签再拷能保证两边都是同一份有效签名。
if [ "$NOTARIZE" = "1" ]; then
  echo "==> 用 Developer ID 重新签名"
  "$ROOT/scripts/sign_release.sh" "$APP"
fi

mkdir -p "$ROOT/dist"
# 同样阻止 Spotlight 索引 dist：只靠 lsregister -u 注销会被系统重新注册回来，
# 必须让 mds 不再扫这个目录（/Applications 那份是正式安装版，不受影响）。
touch "$ROOT/dist/.metadata_never_index"
rm -rf "$ROOT/dist/LaunchPad.app"
cp -R "$APP" "$ROOT/dist/LaunchPad.app"

# 本机上的「正式安装版」：装过就顺手用新构建覆盖，保证电脑上留的永远是最新版，
# 同时它也作为唯一允许注册的副本（见下面的 LS 去重）。
INSTALLED="/Applications/LaunchPad.app"
WANT="$ROOT/dist/LaunchPad.app"
if [ -d "$INSTALLED" ]; then
  rm -rf "$INSTALLED"
  cp -R "$ROOT/dist/LaunchPad.app" "$INSTALLED"
  WANT="$INSTALLED"
  echo "==> 已更新安装版：${INSTALLED}"
fi

# 只让 WANT 这一份被系统识别，其余全注销
#
# 为什么需要这么麻烦：xcodebuild（以及 Xcode GUI 编译）会把 .app 产物注册进
# LaunchServices，而 Spotlight / 聚焦的「应用程序」结果就是读 LaunchServices 的。
# 于是构建目录里那份 + 交付版这份会同时出现，聚焦里搜出「同名的两个 LaunchPad」。
# .metadata_never_index 只能阻止 Spotlight 索引文件内容，挡不住 LS 注册，
# 所以每次构建后必须把除 WANT 之外的所有同 id 注册全部注销掉。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then

  # 列出 LS 数据库里 identifier 为 com.story5.launchpad 的所有注册路径。
  # 必须逐条记录解析：遇到分隔线就清空 cur，保证 path 与 identifier 来自同一条记录。
  # （早先版本用 awk 记住「最近的 path」，跨越记录时会拿到别人的 path，
  #   结果把系统自带的 Share Screen Request.app 也注销了 —— 教训。）
  list_registrations() {
    "$LSREGISTER" -dump 2>/dev/null | while IFS= read -r line; do
      case "$line" in
        "----------"*) cur="" ;;
        "path: "*)
          p="${line#path:}"
          p="${p#"${p%%[! ]*}"}"                 # 去掉 "path:" 后面那一长串对齐空格
          case "$p" in *" (0x"*) p="${p% (0x*}" ;; esac
          cur="$p" ;;
        "identifier: "*)
          case "$line" in
            *com.story5.launchpad) [ -n "$cur" ] && printf '%s\n' "$cur" ;;
          esac ;;
      esac
    done
  }

  list_registrations | sort -u > /tmp/lp-registrations.txt
  while IFS= read -r p; do
    [ "$p" = "$WANT" ] && continue
    "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true
    echo "    注销重复注册：${p}"
  done < /tmp/lp-registrations.txt

  # 注销/注册都是异步落到 LS 数据库的，隔一下再校验，否则读到的还是旧状态
  sleep 1
  "$LSREGISTER" -f "$WANT" >/dev/null 2>&1 || true
  sleep 1

  LEFT=$(list_registrations | sort -u | wc -l | tr -d ' ')
  echo "==> LaunchServices 中 LaunchPad 注册数：${LEFT}（应为 1）"
fi

# 已经装到 /Applications 时，dist 里这份就是多余的，而且删不掉注册：
# 该目录早就被 Spotlight 索引过，单纯注销几秒后系统又会把它注册回来
# （.metadata_never_index 只对「从没被索引过」的目录有效）。所以直接移除文件，
# 只在 dist 保留发布用的 zip。没装到 /Applications 时才保留 dist/LaunchPad.app 作为运行版。
if [ "$NOTARIZE" = "1" ]; then
  # 打 dmg + 签名 + 公证 + 装订票据（内部会调 make_dmg.sh，不再重复打一次）
  "$ROOT/scripts/notarize.sh"
elif [ "$MAKE_DMG" = "1" ]; then
  # 打 dmg（脚本自己从 .build 取产物，不依赖 dist/LaunchPad.app）
  "$ROOT/scripts/make_dmg.sh"
fi

if [ -d "$INSTALLED" ]; then
  rm -rf "$ROOT/dist/LaunchPad.app"
  echo "==> 已移除多余的 dist/LaunchPad.app（本机以 ${INSTALLED} 为唯一副本）"
fi

echo "==> 完成：$ROOT/dist/LaunchPad.app"
echo "    安装：cp -R \"$ROOT/dist/LaunchPad.app\" /Applications/（装过之后脚本会自动覆盖更新它）"
echo "    运行：open \"${WANT}\"（启动后按 F4 或点菜单栏图标）"
