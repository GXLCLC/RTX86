#!/bin/bash
# ============================================================
# fetch_thirdparty.sh - 第三方软件源拉取（浅克隆 + 前置校验）
# 用法: bash scripts/fetch_thirdparty.sh <源码目录>
# 拉取优先级: 官方 feeds 已由工作流先前同步，此处追加第三方源
# 拉取方式  : git clone --depth=1 --filter=tree:0（浅克隆，不下载完整历史）
# 前置校验  : 仓库连通性 / 目标分支存在性 / 插件目录与 Makefile 完整性
# ============================================================
set -euo pipefail

SRC="${1:-lede}"
cd "$SRC"

# ---- 第三方源清单: 本地目录名|仓库地址|分支名 ----
THIRD_REPOS=(
  "kenzok8|https://github.com/kenzok8/openwrt-packages|master"
  "small-package|https://github.com/kenzok8/small-package|main"
  "turboacc|https://github.com/mufeng05/turboacc|main"
)

# ---- 各源中必须存在的插件目录（用于完整性校验） ----
declare -A NEED_DIRS=(
  [kenzok8]="ddnsto luci-app-ddnsto"
  [small-package]="adguardhome easytier luci-app-easytier oaf open-app-filter luci-app-oaf"
  [turboacc]="add_turboacc.sh lede/luci-app-turboacc lede/fullconenat-nft custom/hack-6.18 custom/fullconenat-nft"
)

# ---- 必须存在的 Makefile 文件（用于完整性校验） ----
NEED_MAKEFILES=(
  "package/kenzok8/luci-app-ddnsto/Makefile"
  "package/kenzok8/ddnsto/Makefile"
  "package/small-package/adguardhome/Makefile"
  "package/small-package/easytier/Makefile"
  "package/small-package/luci-app-easytier/Makefile"
  "package/small-package/oaf/Makefile"
  "package/small-package/open-app-filter/Makefile"
  "package/small-package/luci-app-oaf/Makefile"
  "package/turboacc/lede/luci-app-turboacc/Makefile"
)

# ==================== 1. 逐个拉取第三方源 ====================
for entry in "${THIRD_REPOS[@]}"; do
  dir="${entry%%|*}"
  url="$(echo "$entry" | cut -d'|' -f2)"
  branch="$(echo "$entry" | cut -d'|' -f3)"

  echo "==> [拉取] $url (分支 $branch)"

  # 1.1 校验仓库连通性与目标分支存在性
  if ! git ls-remote --exit-code --heads "$url" "$branch" >/dev/null 2>&1; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "错误: 仓库 $url 无法连通，或分支 $branch 不存在"
    echo "修复建议:"
    echo "  1) 检查 GitHub 网络连通性后重试"
    echo "  2) 访问 $url 确认默认分支名是否变更，并同步修改本脚本 THIRD_REPOS"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
  fi

  # 1.2 浅克隆子目录（不下载完整仓库历史，减少耗时）
  rm -rf "package/$dir"
  git clone --depth=1 --filter=tree:0 --branch "$branch" "$url" "package/$dir" \
    || { echo "错误: 浅克隆 $url 失败"; exit 1; }
  echo "    -> 已浅克隆到 package/$dir ($(du -sh package/$dir | cut -f1))"
done

# ==================== 2. 插件目录完整性校验 ====================
echo "==> [校验] 第三方源插件目录完整性"
MISS=0
for src in "${!NEED_DIRS[@]}"; do
  for item in ${NEED_DIRS[$src]}; do
    if [ ! -e "package/$src/$item" ]; then
      echo "    缺失: package/$src/$item"
      MISS=1
    fi
  done
done
if [ "$MISS" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: 第三方源插件目录校验失败（上方缺失项）"
  echo "修复建议: 对应仓库可能调整了目录结构，请到仓库确认最新目录名，"
  echo "          并同步修改本脚本 NEED_DIRS / NEED_MAKEFILES 列表"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi

# ==================== 3. Makefile 完整性校验 ====================
echo "==> [校验] 插件 Makefile 完整性"
for mk in "${NEED_MAKEFILES[@]}"; do
  if [ ! -f "$mk" ]; then
    echo "    缺失文件: $mk"
    MISS=1
  fi
done
if [ "$MISS" -ne 0 ]; then
  echo "错误: Makefile 校验失败，请检查上游仓库变动"
  exit 1
fi

echo "==> 第三方软件源拉取与前置校验全部通过"
