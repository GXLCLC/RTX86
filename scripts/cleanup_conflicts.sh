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

# ============================================================
# 1/4 移除与核心源码包同名的第三方目录（消除包扫描同名竞争）
# ============================================================
# OpenWrt 的包扫描按【目录名】去重（不是包名，也不是完整路径）:
#   include/scan.mk:
#     find -L package -mindepth 1 -maxdepth 5 -name Makefile \
#       | xargs grep -aHE 'call (Build/DefaultTargets|BuildPackage|KernelPackage)' \
#       | sed -e 's#^package/##' -e 's#/Makefile:.*##' \
#       | awk -f include/scan.awk
#   include/scan.awk: PKGS[$NF]=$0     ($NF 即目录名)
# 同名目录只有一个能进入编译，谁留下取决于 find 的 readdir 顺序
# （文件系统返回顺序，不可控、不可复现）。
#
# 第三方源中存在大量与核心源码包同名的目录，例如 small-package/ 下的
# opkg、base-files、firewall、firewall4、dnsmasq、nftables、libnftnl、
# ppp、ucl、upx、apk、rpcd、ucode、wireless-regdb、fullconenat、
# fullconenat-nft、adbyby、autocore、ipv6-helper、mentohust、
# vsftpd-alt 等（lean master 已将 fullconenat/shortcut-fe 等并入
# 官方源码，同名目录比早期版本更多）。一旦第三方版在扫描中"赢"了
# 核心版，后果有两类:
#   a) 编译直接崩溃: package/Makefile 在 CONFIG_USE_APK 未启用时硬依赖
#      package/system/opkg/host/compile，核心 opkg 规则消失即报
#        make[2]: *** No rule to make target
#                  'package/system/opkg/host/compile',
#                  needed by 'package/compile'. Stop.
#   b) 更隐蔽: 固件混入第三方魔改的核心组件（base-files/firewall 等），
#      现场难排查
#
# 这些同名目录在 OpenWrt 构建中本就是死代码（同名必被去重，永远不可能
# 被编译），显式删除零功能损失，且把不可控的 readdir 竞争变成确定结果:
# 核心源码版永远唯一。核心包名从当前源码树动态提取，上游日后新增同名
# 目录也会被自动覆盖，无需维护清单。
echo "==> [1/4] 移除与核心源码包同名的第三方目录（消除包扫描同名竞争）"

CORE_NAMES=$(mktemp)
trap 'rm -f "$CORE_NAMES"' EXIT
find -L package -mindepth 1 -maxdepth 5 -name Makefile \
  -not -path 'package/feeds/*' \
  -not -path 'package/kenzok8/*' \
  -not -path 'package/small-package/*' \
  -not -path 'package/turboacc/*' \
  | xargs grep -lE 'call (Build/DefaultTargets|BuildPackage|KernelPackage)' \
  | sed 's#/Makefile$##' | awk -F/ '{print $NF}' | sort -u > "$CORE_NAMES" || true
echo "    核心源码包目录名基准: $(wc -l < "$CORE_NAMES") 个（从当前源码树动态提取）"

REMOVED=0
for src in kenzok8 small-package turboacc; do
  [ -d "package/$src" ] || continue
  while IFS= read -r mk; do
    d=$(dirname "$mk")
    base=$(basename "$d")
    if grep -qxF "$base" "$CORE_NAMES"; then
      rm -rf "$d"
      echo "    已删除与核心包同名: $d"
      REMOVED=$((REMOVED + 1))
    fi
  done < <(find -L "package/$src" -mindepth 1 -maxdepth 5 -name Makefile 2>/dev/null)
done
echo "    共移除 $REMOVED 个与核心源码包同名的第三方目录"

# ============================================================
# 2/4 删除与官方 feeds 重复的第三方插件目录（保留官方 feeds 版本）
# ============================================================
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

echo "==> [2/4] 删除与官方 feeds 重复的第三方插件目录"
for d in "${CONFLICT_DIRS[@]}"; do
  # -L 兜底: 目录被删后其 package/feeds/<feed>/ 下的符号链接会变成断链，
  # [ -e ] 对断链返回 false，必须用 -L 检测符号链接本身才能清除干净
  if [ -e "$d" ] || [ -L "$d" ]; then
    rm -rf "$d"
    echo "    已删除冲突目录: $d"
  fi
done

echo "==> [3/4] 删除第三方源中的预编译 ipk（禁止外部预编译内核模块）"
# 预编译 kmod 与当前编译内核版本不匹配会直接导致依赖冲突，
# 所有内核模块一律随源码内核现场编译，保证版本严格一致
find package -name "*.ipk" -type f -print -delete 2>/dev/null || true
IPK_LEFT=$(find package -name "*.ipk" -type f 2>/dev/null | wc -l)
echo "    剩余预编译 ipk: $IPK_LEFT"

echo "==> [4/4] 删除 shortcut-fe 多余组件（仅保留 turboacc 三功能）"
# 用户要求 turboacc 仅保留 流量分载/全锥NAT/BBR。
# simulated-driver 是 shortcut-fe 的可选配套驱动，无任何 LuCI 应用引用，
# 显式移除防止依赖链误装；lean 核心源码版（package/qca/shortcut-fe/）与
# turboacc 拷贝版（package/turboacc/shortcut-fe/，已由第 1 步同名清理
# 删除目录下的同名子项）都要清。
# 注意: fast-classifier 目录必须保留——luci-app-turboacc 的 LUCI_DEPENDS
# 静态引用 kmod-fast-classifier，删除会让每次包扫描都报警；且它属于
# FastPath Engine choice（默认 FLOW_OFFLOADING），config 不选中即不会
# 编译，"剔除组件"的意图由 config 开关保证，无需删除目录
for d in \
  "package/qca/shortcut-fe/simulated-driver" \
  "package/turboacc/shortcut-fe/simulated-driver" \
  "package/turboacc/lede/shortcut-fe/simulated-driver"; do
  if [ -e "$d" ]; then
    rm -rf "$d"
    echo "    已删除多余组件: $d"
  fi
done

echo "==> 冲突清理完成"
