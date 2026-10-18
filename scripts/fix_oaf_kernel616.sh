#!/bin/bash
# ============================================================
# fix_oaf_kernel616.sh - 修复 open-app-filter 对内核 6.16+ 的 API 兼容性
# 用法: bash scripts/fix_oaf_kernel616.sh <源码目录>
#
# 背景:
#   open-app-filter（kmod-oaf，官方 packages feed）钉版
#   2025-07-03-a9e4637b，其内核模块仍用 Linux 6.16 已移除的旧定时器
#   API（del_timer_sync / from_timer）。lean master 的 x86_64 目标
#   使用 6.18 内核，编译在末段报错（run 7 实证，构建 3.5 小时后）：
#       app_filter.c:1568:9: error: implicit declaration of
#       function 'del_timer_sync' [-Werror=implicit-function-declaration]
#   上游 destan19/OpenAppFilter 已于 2025-10-30（commit bf7b19e662）
#   修复：6.16+ 改用 timer_delete_sync() / timer_container_of()，
#   并以 LINUX_VERSION_CODE 守卫保持对旧内核的兼容——但官方 feed
#   尚未同步该提交。
#
# 处置:
#   把上游修复制成 quilt 补丁（scripts/patches/
#   001-oaf-kernel-6.16-timer-api.patch，按钉版 a9e4637b 制作）
#   注入 feed 包的 patches/ 目录。注入前按 Makefile 中的真实版本
#   下载源码干跑校验：
#     - 干跑通过           -> 写入补丁（feed 版本即预期版本）
#     - 干跑失败且源码已用新 API -> 上游已同步修复，警告并跳过
#     - 干跑失败且源码仍用旧 API -> 结构已变，报错退出（loud failure）
#     - 源码下载失败       -> 仍写入补丁但显著警告（补丁针对已验证的
#                           钉版制作，未校验安装优于放弃修复）
# ============================================================
set -uo pipefail

SRC="${1:-lede}"

# 补丁文件随本脚本存放（scripts/patches/），与 cwd 无关
# 必须在 cd "$SRC" 之前解析: 工作流以相对路径调用（bash scripts/fix_oaf_kernel616.sh），
# cd 后再用相对 $BASH_SOURCE 解析会落到 $SRC/scripts/ 下，补丁必然找不到
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_SRC="$SCRIPT_DIR/patches/001-oaf-kernel-6.16-timer-api.patch"

cd "$SRC" || exit 1

PKG_DIR="package/feeds/packages/net/open-app-filter"
PATCH_NAME="001-oaf-kernel-6.16-timer-api.patch"

if [ ! -f "$PATCH_SRC" ]; then
  echo "错误: 补丁文件不存在: $PATCH_SRC" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- 从 Makefile 提取变量（:= = ?= += 四种赋值形式都兼容）----
get_var() {
  sed -n "s/^$2[[:space:]]*[:?+]*= *//p" "$1/Makefile" | head -1
}

expand_val() {
  local dir="$1" v="$2"
  v="${v//\$(PKG_NAME)/$(get_var "$dir" PKG_NAME)}"
  v="${v//\$(PKG_VERSION)/$(get_var "$dir" PKG_VERSION)}"
  echo "$v"
}

# ---- 带重试的下载 + tar tf 有效性校验（404 页面也非空，必须过 tar tf）----
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

echo "==> [oaf 修复] open-app-filter 内核 6.16+ 定时器 API 兼容性"

# ---- 包不存在（feed 结构调整/未选 oaf）-> 无事可做 ----
if [ ! -d "$PKG_DIR" ]; then
  echo "    未找到 $PKG_DIR（feed 结构可能已调整或未安装 oaf），跳过"
  exit 0
fi

# ---- 幂等: 补丁已存在且内容一致 -> 跳过 ----
mkdir -p "$PKG_DIR/patches"
if [ -f "$PKG_DIR/patches/$PATCH_NAME" ]; then
  if cmp -s "$PATCH_SRC" "$PKG_DIR/patches/$PATCH_NAME"; then
    echo "    补丁已存在且一致（$PATCH_NAME），跳过（幂等）"
    exit 0
  fi
  echo "    警告: 已存在同名补丁但内容不同，以仓库版本覆盖"
fi

# ---- 读取源码坐标 ----
proto=$(get_var "$PKG_DIR" PKG_SOURCE_PROTO)
src_ver=$(get_var "$PKG_DIR" PKG_SOURCE_VERSION)
src_url=$(expand_val "$PKG_DIR" "$(get_var "$PKG_DIR" PKG_SOURCE_URL)")
src_file=$(expand_val "$PKG_DIR" "$(get_var "$PKG_DIR" PKG_SOURCE)")
echo "    源码: ${src_url:-<tarball>} @ ${src_ver:-$src_file}"

pristine="$WORK/pristine"
mkdir -p "$pristine"
got_source=0

if [ "$proto" = "git" ]; then
  # git 包: 取 URL basename 作仓库名（firewall3 式目录名/仓库名不一致的坑）
  git_repo=$(basename "${src_url%.git}")
  if printf '%s' "$src_url" | grep -q 'github\.com'; then
    git_owner=$(printf '%s' "$src_url" | sed -E 's#.*github\.com/##; s#\.git.*##' | cut -d/ -f1)
  else
    git_owner=openwrt
  fi
  codeload="https://codeload.github.com/${git_owner}/${git_repo}/tar.gz/${src_ver}"
  if fetch "$codeload" "$WORK/src.tar.gz"; then
    tar xzf "$WORK/src.tar.gz" -C "$pristine" --strip-components=1 && got_source=1
  fi
else
  tarball_url="${src_url%/}/$src_file"
  if [ -f "dl/$src_file" ]; then
    if cp "dl/$src_file" "$WORK/" && tar xf "$WORK/$src_file" -C "$pristine" --strip-components=1 2>/dev/null; then
      got_source=1
    fi
  elif fetch "$tarball_url" "$WORK/$src_file"; then
    tar xf "$WORK/$src_file" -C "$pristine" --strip-components=1 2>/dev/null && got_source=1
  fi
fi

# ---- 三态决策 ----
if [ "$got_source" -eq 1 ]; then
  if (cd "$pristine" && patch -p1 -E --dry-run < "$PATCH_SRC") >"$WORK/dryrun.log" 2>&1; then
    cp "$PATCH_SRC" "$PKG_DIR/patches/$PATCH_NAME"
    echo "    [OK] 干跑通过，补丁已写入 $PKG_DIR/patches/$PATCH_NAME"
  else
    # 干跑失败: 区分"上游已修复"与"结构已变"
    # 注意: 上游修复（bf7b19e662）把旧 API 保留在 < 6.16 的版本守卫内，
    # 因此不能靠 grep 旧 API 判断，必须检测新 API 是否已出现
    if grep -rqE 'timer_delete_sync|timer_container_of' "$pristine/oaf/src" 2>/dev/null; then
      echo "    警告: 源码已使用新定时器 API（上游应已同步修复），跳过注入"
      exit 0
    else
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "错误: 源码仍在使用旧定时器 API，但补丁无法应用（版本结构已变）"
      echo "干跑日志:"
      tail -5 "$WORK/dryrun.log" | sed 's/^/    /'
      echo "处置: 需针对新版本重新制作补丁（参照上游 bf7b19e662）"
      echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      exit 1
    fi
  fi
else
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "警告: 无法下载 oaf 源码进行干跑校验（网络瞬时故障）"
  echo "      补丁按已验证钉版（a9e4637b）制作，仍然注入；"
  echo "      若 feed 期间更换版本导致补丁失效，构建会在 oaf 阶段"
  echo "      报 quilt 错误（早于编译错误，可诊断）"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  cp "$PATCH_SRC" "$PKG_DIR/patches/$PATCH_NAME"
fi

echo "==> oaf 内核兼容性修复完成"
