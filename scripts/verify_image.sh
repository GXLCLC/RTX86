#!/bin/bash
# ============================================================
# verify_image.sh - 编译产物镜像校验（不达标直接终止任务）
# 用法: bash scripts/verify_image.sh <bin目录>
# 校验项:
#   1. 镜像存在性（lean x86_64 实际产出的磁盘镜像，候选发现）
#   2. 文件格式（DOS/MBR 磁盘镜像 + gzip 完整性）
#   3. GPT 分区表解析
#   4. rootfs 分区容量 >= 2 GiB（overlay 可写分区要求）
#   5. squashfs 文件系统结构完整性
#
# 镜像定位说明（run 12 实证，勿改回 sysupgrade 硬编码名）:
#   lean x86_64 目标只产出 combined(.efi).img(.gz) 与 rootfs.img(.gz)，
#   target/linux/x86/image/Makefile 中不存在任何 sysupgrade 目标
#   （沙箱 grep + GitHub live API 双重确认 sysupgrade 出现次数: 0）。
#   镜像配置默认值: GRUB_EFI_IMAGES=y / GRUB_IMAGES=n /
#   TARGET_IMAGES_GZIP=y，故实际产物为:
#     openwrt-x86-64-generic-squashfs-rootfs.img.gz      (仅 rootfs)
#     openwrt-x86-64-generic-squashfs-combined-efi.img.gz(GPT 磁盘镜像)
#   combined-efi = GPT + p1 kernel(FAT, 含 vmlinuz/grub efi) +
#   p2 rootfs(2048MiB squashfs) + 尾部 padding；
#   `file` 对 GPT 镜像报 "DOS/MBR boot sector"（保护性 MBR），
#   sfdisk --json / max-start/max-size 启发式 / unsquashfs -s 均适配。
#   本脚本按候选顺序发现镜像；.gz 输入先解压到临时文件再校验。
# ============================================================
set -euo pipefail

BIN_DIR="${1:?用法: bash scripts/verify_image.sh <bin目录>}"
cd "$BIN_DIR"

TMP_IMG=""
cleanup() { [ -n "$TMP_IMG" ] && rm -f "$TMP_IMG"; }
trap cleanup EXIT

echo "==> [1/5] 镜像存在性校验（候选: combined-efi > combined > glob 兜底 > sysupgrade 兼容名）"
IMG_SRC=""
for cand in \
  openwrt-x86-64-generic-squashfs-combined-efi.img.gz \
  openwrt-x86-64-generic-squashfs-combined-efi.img \
  openwrt-x86-64-generic-squashfs-combined.img.gz \
  openwrt-x86-64-generic-squashfs-combined.img \
  $(ls *-squashfs-combined*.img.gz *-squashfs-combined*.img 2>/dev/null || true) \
  openwrt-x86-64-generic-squashfs-sysupgrade.img.gz \
  openwrt-x86-64-generic-squashfs-sysupgrade.img; do
  if [ -f "$cand" ]; then
    IMG_SRC="$cand"
    break
  fi
done

if [ -z "$IMG_SRC" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: 未找到可校验的磁盘镜像（$BIN_DIR）"
  echo "bin 目录实际内容:"
  ls -lh
  echo "修复建议: 确认编译产出 *-squashfs-combined-efi.img(.gz)；"
  echo "          lean x86_64 不产出 sysupgrade.img，请检查 config 中"
  echo "          CONFIG_GRUB_EFI_IMAGES / CONFIG_TARGET_IMAGES_GZIP 是否生效"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi
echo "发现镜像: $IMG_SRC"

# .gz 输入先解压到临时文件，后续 file/sfdisk/dd/unsquashfs 统一走未压缩镜像
if [ "${IMG_SRC%.gz}" != "$IMG_SRC" ]; then
  echo "gzip 完整性预检: $IMG_SRC"
  gzip -t "$IMG_SRC" || { echo "错误: $IMG_SRC gzip 结构损坏"; exit 1; }
  TMP_IMG=$(mktemp /tmp/verify_image.XXXXXX.img)
  gunzip -c "$IMG_SRC" > "$TMP_IMG"
  IMG="$TMP_IMG"
else
  IMG="$IMG_SRC"
fi
ls -lh "$IMG_SRC"

echo "==> [2/5] 文件格式校验"
file "$IMG"
# GPT 磁盘镜像带保护性 MBR，file 同样报 "DOS/MBR boot sector"
file "$IMG" | grep -qi "DOS/MBR boot sector" \
  || { echo "错误: $IMG_SRC 不是有效的磁盘镜像"; exit 1; }
echo "磁盘镜像格式: 通过（保护性 MBR / GPT 或 MBR 分区磁盘镜像）"
if [ "${IMG_SRC%.gz}" != "$IMG_SRC" ]; then
  echo "gzip 完整性: 通过"
fi

echo "==> [3/5] 分区表解析（MBR/GPT 均可识别）"
sfdisk --json "$IMG" > /tmp/part.json
jq -r '.partitiontable.partitions[] | "分区 \(.node): start=\(.start) size=\(.size) sectors (\(.size*512/1024/1024) MiB)"' /tmp/part.json
# rootfs 分区取扇区数最大的分区（boot/kernel 分区远小于 rootfs）
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
echo "==> 镜像全部校验通过（$IMG_SRC: 分区 >= 2GiB / 格式正确 / squashfs 完整 / gzip 完好）"
