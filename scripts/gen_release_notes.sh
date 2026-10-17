#!/bin/bash
# ============================================================
# gen_release_notes.sh - 生成 Release 自动发布内容
# 用法: bash scripts/gen_release_notes.sh <源码目录>   （输出到 stdout）
# 内容: 源码 commit 号 / 内核版本 / 编译时间 / 插件清单（过滤所有 kmod）
# ============================================================
set -euo pipefail

SRC_DIR="${1:-lede}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/config/x86_64.config"

# ---- 源码 commit 号 ----
COMMIT=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
COMMIT_SHORT=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ---- 内核版本（优先取编译产物 utsrelease.h，回退 include/kernel-*） ----
KVER=""
for f in "$SRC_DIR"/build_dir/target-*/linux-*/include/generated/utsrelease.h; do
  if [ -f "$f" ]; then
    KVER=$(grep -o '"[^"]*"' "$f" | head -1 | tr -d '"')
    break
  fi
done
if [ -z "$KVER" ]; then
  KVER=$(grep -m1 "^LINUX_VERSION-" "$SRC_DIR"/include/kernel-* 2>/dev/null \
    | sed 's/.*= *//' | tr -d '[:space:]' | sed 's/^\.//')
fi
[ -n "$KVER" ] || KVER="unknown"

# ---- 编译时间（Asia/Shanghai） ----
BUILD_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# ---- 插件清单（从编译配置提取，过滤所有 kmod 内核模块与 turboacc 功能开关） ----
PKGS=$(grep "^CONFIG_PACKAGE_" "$CONFIG_FILE" \
  | sed 's/[[:space:]]*#.*$//' \
  | sed 's/^CONFIG_PACKAGE_//; s/=y$//' \
  | grep -v "^kmod-" \
  | grep -v "^TURBOACC_INCLUDE_" \
  | sort -u)

cat <<EOF
## 固件信息

| 项目 | 内容 |
| --- | --- |
| 源码仓库 | [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) (master) |
| 源码 Commit | \`${COMMIT}\` |
| 内核版本 | ${KVER} |
| 编译时间 | ${BUILD_TIME} (Asia/Shanghai) |
| 编译环境 | Ubuntu 24.04 LTS + GitHub Actions |
| 默认后台 | http://192.168.2.1 |
| 登录账号 | \`root\` |
| 登录密码 | \`12345678\` |
| 固件格式 | x86_64 Generic / squashfs sysupgrade / overlay 2 GiB |

## 插件清单

EOF

# 逐行输出插件（已过滤 kmod 内核模块）
echo "$PKGS" | while read -r pkg; do
  [ -n "$pkg" ] && echo "- ${pkg}"
done

cat <<'EOF'

## 刷机说明

1. 下载 `*-lede-x86_64-squashfs.img.gz` 并解压得到 `.img` 磁盘镜像；
2. 使用 Rufus / Etcher / dd 写入硬盘或 U 盘（DD 镜像模式）；
3. 从该盘引导启动，浏览器访问 `http://192.168.2.1`，账号 `root`，密码 `12345678`；
4. overlay 可写分区已扩至 2 GiB，安装插件与配置重启后保留。

> 本固件由 GitHub Actions 自动编译并自动发布，无人值守交付。
EOF
