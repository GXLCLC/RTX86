#!/bin/bash
# =====================================================================
# 04-verify-image.sh —— 编译产物自动校验
# 校验：1) 目标镜像存在  2) squashfs 格式  3) 根分区总大小（默认+2G 扩容）
# 任一项不达标直接终止流程
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 04-verify-image.sh <lede源码目录>}"
IMG_DIR="${LEDE_DIR}/bin/targets/x86/64"
MIN_ROOTFS_MB=2048    # 扩容要求：根分区不低于 2G

echo "===== 1/3 校验目标镜像是否存在 ====="
IMG_GZ=$(find "$IMG_DIR" -maxdepth 1 -name "*squashfs-combined-efi.img.gz" | head -n1)
if [ -z "$IMG_GZ" ]; then
    echo "ERROR: 未找到 squashfs-combined-efi.img.gz 目标镜像，判定编译失败"
    echo "修复建议：检查 .config 中 x86_64 generic 目标与 squashfs 根文件系统是否启用"
    exit 1
fi
echo "OK: $IMG_GZ"

echo "===== 2/3 校验 squashfs 格式与压缩包完整性 ====="
echo "$IMG_GZ" | grep -q "squashfs" || { echo "ERROR: 镜像非 squashfs 格式"; exit 1; }
gzip -t "$IMG_GZ" || { echo "ERROR: img.gz 压缩包损坏"; exit 1; }
echo "OK: squashfs 格式且压缩包完整"

echo "===== 3/3 校验根分区总大小（不小于 ${MIN_ROOTFS_MB}MB，含 2G 扩容）====="
gzip -dc "$IMG_GZ" > /tmp/check.img
PART2=$(fdisk -l /tmp/check.img 2>/dev/null | awk '/check.img2/ {print $2, $3}')
START_SEC=$(echo "$PART2" | awk '{print $1}')
END_SEC=$(echo "$PART2" | awk '{print $2}')
ROOTFS_MB=$(( (END_SEC - START_SEC + 1) * 512 / 1048576 ))
echo "根分区（rootfs）实际大小：${ROOTFS_MB}MB"
if [ "$ROOTFS_MB" -lt "$MIN_ROOTFS_MB" ]; then
    echo "ERROR: 根分区 ${ROOTFS_MB}MB 未达到 ${MIN_ROOTFS_MB}MB（2G 扩容）要求，判定失败"
    echo "修复建议：检查 config 中 CONFIG_TARGET_ROOTFS_PARTSIZE 是否设置扩容"
    exit 1
fi
rm -f /tmp/check.img
echo "===== 校验全部通过 ====="
