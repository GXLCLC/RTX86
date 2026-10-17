#!/bin/bash
# ============================================================
# verify_image.sh - 编译产物镜像校验（不达标直接终止任务）
# 用法: bash scripts/verify_image.sh <bin目录>
# 校验项:
#   1. 镜像存在性（squashfs sysupgrade img + img.gz）
#   2. 文件格式（DOS/MBR 磁盘镜像 + gzip 完整性）
#   3. GPT 分区表解析
#   4. rootfs 分区容量 >= 2 GiB（overlay 可写分区要求）
#   5. squashfs 文件系统结构完整性
# ============================================================
set -euo pipefail

BIN_DIR="${1:?用法: bash scripts/verify_image.sh <bin目录>}"
cd "$BIN_DIR"

IMG="openwrt-x86-64-generic-squashfs-sysupgrade.img"     # 未压缩磁盘镜像
IMG_GZ="${IMG}.gz"                                       # gzip 压缩成品

echo "==> [1/5] 镜像存在性校验"
if [ ! -f "$IMG" ]; then
  echo "错误: 未找到 $IMG（$BIN_DIR）"
  echo "修复建议: 检查 config/x86_64.config 中 CONFIG_TARGET_ROOTFS_SQUASHFS=y 是否生效"
  exit 1
fi
if [ ! -f "$IMG_GZ" ]; then
  echo "错误: 未找到 $IMG_GZ，判定编译失败"
  exit 1
fi
ls -lh "$IMG" "$IMG_GZ"

echo "==> [2/5] 文件格式校验"
file "$IMG"
file "$IMG" | grep -qi "DOS/MBR boot sector" \
  || { echo "错误: $IMG 不是有效的磁盘镜像"; exit 1; }
gzip -t "$IMG_GZ" || { echo "错误: $IMG_GZ gzip 结构损坏"; exit 1; }
echo "gzip 完整性: 通过"

echo "==> [3/5] GPT 分区表解析"
sfdisk --json "$IMG" > /tmp/part.json
jq -r '.partitiontable.partitions[] | "分区 \(.node): start=\(.start) size=\(.size) sectors (\(.size*512/1024/1024) MiB)"' /tmp/part.json
# rootfs 分区取扇区数最大的分区（boot 分区远小于 rootfs）
ROOTFS_START=$(jq -r '[.partitiontable.partitions[].start] | max' /tmp/part.json)
ROOTFS_SIZE=$(jq -r '[.partitiontable.partitions[].size] | max' /tmp/part.json)
ROOTFS_BYTES=$((ROOTFS_SIZE * 512))
echo "rootfs 分区: 起始扇区 $ROOTFS_START / 大小 $ROOTFS_BYTES 字节 ($((ROOTFS_BYTES/1024/1024)) MiB)"

echo "==> [4/5] overlay 分区容量校验（要求 >= 2 GiB）"
MIN_BYTES=$((2*1024*1024*1024 - 16*1024*1024)) # 2 GiB，允许 16 MiB 误差
if [ "$ROOTFS_BYTES" -lt "$MIN_BYTES" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: rootfs 分区仅 $((ROOTFS_BYTES/1024/1024)) MiB，未达到 2 GiB overlay 要求"
  echo "修复建议: 确认 config/x86_64.config 中 CONFIG_TARGET_ROOTFS_PARTSIZE=2048 已写入并生效"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi
echo "通过: rootfs 分区容量 >= 2 GiB"

echo "==> [5/5] squashfs 完整性校验"
dd if="$IMG" of=/tmp/rootfs.squashfs bs=512 skip="$ROOTFS_START" count="$ROOTFS_SIZE" status=none
file /tmp/rootfs.squashfs
file /tmp/rootfs.squashfs | grep -qi "Squashfs filesystem" \
  || { echo "错误: rootfs 分区不是有效的 squashfs 文件系统"; exit 1; }
unsquashfs -s /tmp/rootfs.squashfs # 读取 superblock，校验结构与完整性
rm -f /tmp/rootfs.squashfs

echo ""
echo "==> 镜像全部校验通过（分区 >= 2GiB / 格式正确 / squashfs 完整 / gzip 完好）"
