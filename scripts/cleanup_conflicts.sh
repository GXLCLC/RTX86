#!/bin/bash
# ============================================================
# cleanup_conflicts.sh - 清理第三方冲突插件与预编译内核模块
# 用法: bash scripts/cleanup_conflicts.sh <源码目录>
# 背景: lean master 官方 feeds 已内置多数 LuCI 应用（smartdns /
#       adguardhome / wechatpush / argon 主题等），第三方源中存在
#       同名重复包，双定义会导致依赖解析冲突，必须只保留一份。
# 约束: 仅保留源码自带内核，禁止引入外部预编译 kmod 内核包。
# ============================================================
set -euo pipefail

SRC="${1:-lede}"
cd "$SRC"

# ---- 冲突目录清单（存在即删除；保留官方 feeds 版本） ----
CONFLICT_DIRS=(
  # kenzok8 源中与官方 feeds 重复的包（保留官方版本）
  "package/kenzok8/luci-app-smartdns"
  "package/kenzok8/smartdns"
  "package/kenzok8/luci-app-adguardhome"
  "package/kenzok8/adguardhome"          # AdGuardHome 主程序保留 small-package 版
  "package/kenzok8/luci-app-argon-config"
  "package/kenzok8/luci-theme-argon"
  "package/kenzok8/luci-app-wechatpush"
  # small-package 中与官方 feeds 重复的包（保留官方版本）
  "package/small-package/luci-app-smartdns"
  "package/small-package/smartdns"
  "package/small-package/luci-app-adguardhome"
  "package/small-package/luci-app-argon-config"
  "package/small-package/luci-theme-argon"
  "package/small-package/luci-app-wechatpush"
  # ddnsto 保留 kenzok8 源版本，删除 small-package 重复版
  "package/small-package/luci-app-ddnsto"
  "package/small-package/ddnsto"
  # easytier: small-package 采用容器目录组织，正版在 luci-app-easytier/ 容器内
  # (luci-app-easytier/{easytier,easytier-noweb,luci-app-easytier})，
  # 根目录的 easytier / easytier-noweb 为遗留副本，PKG_NAME 与容器内同名，
  # 双定义会导致依赖解析冲突，删除根目录版保留容器版
  "package/small-package/easytier"
  "package/small-package/easytier-noweb"
  # luci-app-turboacc 由 package/turboacc（mufeng05 补丁配套版）接管，
  # 删除官方 feed 版避免同名双定义（源目录 + feeds install 符号链接都要删）
  "feeds/luci/applications/luci-app-turboacc"
  "package/feeds/luci/luci-app-turboacc"
)

echo "==> [1/3] 删除与官方 feeds 重复的第三方插件目录"
for d in "${CONFLICT_DIRS[@]}"; do
  # -L 兜底: 目录被删后其 package/feeds/<feed>/ 下的符号链接会变成断链，
  # [ -e ] 对断链返回 false，必须用 -L 检测符号链接本身才能清除干净
  if [ -e "$d" ] || [ -L "$d" ]; then
    rm -rf "$d"
    echo "    已删除冲突目录: $d"
  fi
done

echo "==> [2/3] 删除第三方源中的预编译 ipk（禁止外部预编译内核模块）"
# 预编译 kmod 与当前编译内核版本不匹配会直接导致依赖冲突，
# 所有内核模块一律随源码内核现场编译，保证版本严格一致
find package -name "*.ipk" -type f -print -delete 2>/dev/null || true
IPK_LEFT=$(find package -name "*.ipk" -type f 2>/dev/null | wc -l)
echo "    剩余预编译 ipk: $IPK_LEFT"

echo "==> [3/3] 删除 shortcut-fe/fast-classifier 多余组件（仅保留 turboacc 三功能）"
# 用户要求 turboacc 仅保留 流量分载/全锥NAT/BBR，
# 以下可选内核模块目录显式移除，防止依赖链误装
for d in \
  "package/turboacc/shortcut-fe/fast-classifier" \
  "package/turboacc/shortcut-fe/simulated-driver"; do
  if [ -e "$d" ]; then
    rm -rf "$d"
    echo "    已删除多余组件: $d"
  fi
done

echo "==> 冲突清理完成"
