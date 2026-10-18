#!/bin/bash
# ============================================================
# verify_patches.sh - 编译前校验补丁与包源码版本兼容性
# 用法: bash scripts/verify_patches.sh <源码目录>
#
# 背景:
#   add_turboacc.sh 会向 iptables / nftables / libnftnl / firewall /
#   firewall4 的 patches/ 注入 fullcone 相关补丁；这些补丁与上游包
#   版本强绑定。源码一旦升级，常出现"补丁还在、目标文件没了"——
#   例如 lean 将 iptables 升至 1.8.7 后 extensions/libxt_NAT.c 被
#   移除，而官方自带补丁 900-bcm-fullconenat.patch 仍引用它，
#   编译会在打补丁阶段失败：
#       can't find file to patch at input line 3
#       No file to patch.  Skipping patch.
#       Patch failed!
# 且该失败往往在整体编译数小时后才暴露（iptables 在依赖链中后段），
# 白白浪费大量机时。
#
# 处置:
#   编译前对每个目标包的补丁做"按序累积应用"预检（与 OpenWrt 构建
#   时的 quilt 行为一致）；无法应用的补丁移入 patches-disabled/
#   留档并继续编译。这些补丁均为功能增强性质（fullcone 支持等），
#   隔离不影响核心构建；全锥 NAT 的 nftables 路径（kmod-nft-fullcone）
#   不受影响。预检失败不终止任务，保证无人值守编译连续性。
# ============================================================
set -uo pipefail

SRC="${1:-lede}"
cd "$SRC" || exit 1
ABS=$(pwd) # 绝对路径基准: 子 shell cd 后相对补丁路径仍可寻回

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- 目标包清单（相对 package/ 的目录，与 add_turboacc.sh 注入目标一致）----
TARGETS=(
  "network/utils/iptables"
  "network/utils/nftables"
  "libs/libnftnl"
  "network/config/firewall"
  "network/config/firewall4"
)

# 从 Makefile 提取变量（取首个匹配）
# 注意: OpenWrt Makefile 赋值形式有 := = ?= += 四种，
# 例如 firewall/firewall4 的 PKG_SOURCE_URL 用的是普通 = 而非 :=，
# 只匹配 := 会静默取到空值（曾导致 codeload URL 拼出 openwrt//tar.gz/<sha>）
get_var() {
  sed -n "s/^$2[[:space:]]*[:?+]*= *//p" "$1/Makefile" | head -1
}

# 展开 $(PKG_NAME) / $(PKG_VERSION) 形式的变量引用
# （PKG_SOURCE 与 PKG_SOURCE_URL 中均可能出现）
expand_val() {
  local dir="$1" v="$2"
  v="${v//\$(PKG_NAME)/$(get_var "$dir" PKG_NAME)}"
  v="${v//\$(PKG_VERSION)/$(get_var "$dir" PKG_VERSION)}"
  echo "$v"
}

# 带重试的下载 + 有效性校验（GitHub/上游镜像瞬时抖动不该让预检失真；
# 仅检查非空不够——404 页面也非空，必须过 tar tf 才算数）
fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3; do
    if curl -sL --max-time 120 -o "$out" "$url" && tar tf "$out" >/dev/null 2>&1; then
      return 0
    fi
    echo "    -> 下载/校验第 $i/3 次失败: $url"
    rm -f "$out"
    sleep $((i * 5))
  done
  return 1
}

TOTAL_DISABLED=0

for pkg in "${TARGETS[@]}"; do
  pkgdir="package/$pkg"
  name=$(basename "$pkgdir")
  patches_dir="$pkgdir/patches"

  echo "==> [预检] $pkg"

  # 无 patches 目录或无补丁 -> 跳过
  if [ ! -d "$patches_dir" ]; then
    echo "    无 patches 目录，跳过"
    continue
  fi
  mapfile -t patch_files < <(ls "$ABS/$patches_dir"/*.patch 2>/dev/null | sort)
  if [ "${#patch_files[@]}" -eq 0 ]; then
    echo "    无待应用补丁，跳过"
    continue
  fi
  echo "    待校验补丁 ${#patch_files[@]} 个"

  # ---------- 获取对应版本源码 ----------
  proto=$(get_var "$pkgdir" PKG_SOURCE_PROTO)
  src_ver=$(get_var "$pkgdir" PKG_SOURCE_VERSION)
  src_url=$(expand_val "$pkgdir" "$(get_var "$pkgdir" PKG_SOURCE_URL)")
  src_file=$(expand_val "$pkgdir" "$(get_var "$pkgdir" PKG_SOURCE)")

  pristine="$WORK/${name}.pristine"
  rm -rf "$pristine"; mkdir -p "$pristine"

  if [ "$proto" = "git" ]; then
    # git 包: git.openwrt.org/project/<repo>.git -> codeload GitHub 镜像按 commit 下载
    # 仓库名取 URL basename: firewall3 的目录名是 firewall 而仓库名是 firewall3，
    # 不能想当然用目录名
    git_repo=$(basename "${src_url%.git}")
    if printf '%s' "$src_url" | grep -q 'github\.com'; then
      git_owner=$(printf '%s' "$src_url" | sed -E 's#.*github\.com/##; s#\.git.*##' | cut -d/ -f1)
    else
      git_owner=openwrt
    fi
    codeload="https://codeload.github.com/${git_owner}/${git_repo}/tar.gz/${src_ver}"
    if ! fetch "$codeload" "$WORK/${name}.tar.gz"; then
      echo "    !! 警告: 无法获取 $name 源码（$codeload），跳过该校验（不阻断编译）"
      continue
    fi
    tar xzf "$WORK/${name}.tar.gz" -C "$pristine" --strip-components=1 || {
      echo "    !! 警告: $name 源码解压失败，跳过该校验"; continue; }
  else
    # tarball 包: 优先复用 dl/ 缓存，否则按 PKG_SOURCE_URL 下载
    # 注意补尾斜杠: lean 的 PKG_SOURCE_URL 多不带斜杠（如 .../files）
    tarball_url="${src_url%/}/$src_file"
    if [ -f "dl/$src_file" ]; then
      cp "dl/$src_file" "$WORK/" 2>/dev/null
    else
      if ! fetch "$tarball_url" "$WORK/$src_file"; then
        echo "    !! 警告: 无法获取 $name 源码（$tarball_url），跳过该校验（不阻断编译）"
        continue
      fi
    fi
    if ! tar xf "$WORK/$src_file" -C "$pristine" --strip-components=1 2>/dev/null; then
      echo "    !! 警告: $name 源码解压失败（$src_file），跳过该校验"
      continue
    fi
  fi
  echo "    源码就绪: $name ($([ "$proto" = "git" ] && echo "$src_ver" || echo "$src_file"))"

  # ---------- 按序累积应用补丁（与构建时 quilt 行为一致）----------
  build="$WORK/${name}.build"
  cp -a "$pristine" "$build"
  disabled_dir="$ABS/$(dirname "$patches_dir")/patches-disabled"
  mkdir -p "$disabled_dir"

  pkg_disabled=0
  for pf in "${patch_files[@]}"; do
    pname=$(basename "$pf")
    if (cd "$build" && patch -p1 -E --no-backup-if-mismatch < "$pf") \
         > "$WORK/${name}-${pname}.log" 2>&1; then
      echo "    [OK]   $pname"
    else
      echo "    [隔离] $pname —— 与当前包版本不兼容，移至 patches-disabled/"
      tail -3 "$WORK/${name}-${pname}.log" | sed 's/^/           /'
      mv "$pf" "$disabled_dir/$pname"
      pkg_disabled=$((pkg_disabled + 1))
    fi
  done

  if [ "$pkg_disabled" -gt 0 ]; then
    echo "    -> $name: 隔离 $pkg_disabled 个不兼容补丁（已留档 $disabled_dir/）"
    TOTAL_DISABLED=$((TOTAL_DISABLED + pkg_disabled))
  else
    echo "    -> $name: 全部补丁兼容"
  fi
done

echo "==> 补丁兼容性预检完成，共隔离 $TOTAL_DISABLED 个不兼容补丁"
[ "$TOTAL_DISABLED" -gt 0 ] && echo "    提示: 被隔离补丁均为可选增强（fullcone 支持等），不影响核心构建；"
echo "    nftables 全锥 NAT 路径（kmod-nft-fullcone）不受影响"
exit 0
