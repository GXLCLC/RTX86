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
# 注意: kenzok8 部分包采用"容器目录"组织（如 small-package/luci-app-easytier/
# 内部嵌套 easytier/ 与 luci-app-easytier/），因此校验不写死层级，
# 统一用自适应查找（优先匹配嵌套容器内的路径）。
declare -A NEED_PKGS=(
  [kenzok8]="ddnsto luci-app-ddnsto"
  [small-package]="adguardhome easytier luci-app-easytier oaf open-app-filter luci-app-oaf"
  [turboacc]=""
)

# turboacc 源固定结构的关键路径
TURBOACC_ITEMS=(
  "add_turboacc.sh"
  "lede/luci-app-turboacc/Makefile"
  "lede/fullconenat-nft/Makefile"
  "custom/fullconenat-nft/Makefile"
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

# 在指定源内按包目录名自适应查找含 Makefile 的目录，
# 按路径深度优先（sort -rn 长路径在前，嵌套容器内的路径优先于
# 根目录遗留副本），与 cleanup_conflicts.sh 的保留策略保持一致
find_pkg_dir() {
  local src="$1" pkg="$2" d
  for d in $(find "package/$src" -maxdepth 3 -type d -name "$pkg" 2>/dev/null \
             | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-); do
    if [ -f "$d/Makefile" ]; then
      echo "${d#package/$src/}"
      return 0
    fi
  done
  return 1
}

MISS=0
for src in "${!NEED_PKGS[@]}"; do
  for pkg in ${NEED_PKGS[$src]}; do
    if p=$(find_pkg_dir "$src" "$pkg"); then
      echo "    找到: package/$src/$p (含 Makefile)"
    else
      echo "    缺失: 源 $src 中未找到含 Makefile 的 $pkg 目录"
      MISS=1
    fi
  done
done

# turboacc 源关键路径校验（固定结构）
for item in "${TURBOACC_ITEMS[@]}"; do
  if [ -e "package/turboacc/$item" ]; then
    echo "    找到: package/turboacc/$item"
  else
    echo "    缺失: package/turboacc/$item"
    MISS=1
  fi
done
# turboacc 内核补丁目录（hack-<版本> 随上游内核适配动态变化，校验至少存在一个）
HACK_DIR=$(ls -d package/turboacc/custom/hack-* 2>/dev/null | head -1)
if [ -n "$HACK_DIR" ]; then
  echo "    找到: $HACK_DIR (内核补丁目录)"
else
  echo "    缺失: package/turboacc/custom/hack-* 补丁目录"
  MISS=1
fi

if [ "$MISS" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: 第三方源插件校验失败（上方缺失项）"
  echo "修复建议: 对应仓库可能调整了目录结构，请到仓库确认最新目录名，"
  echo "          并同步修改本脚本 NEED_PKGS 列表"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi

echo "==> 第三方软件源拉取与前置校验全部通过"
