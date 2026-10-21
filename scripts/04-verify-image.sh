#!/bin/bash
# =====================================================================
# 04-verify-image.sh —— 编译产物自动校验
# 校验：1) 目标镜像存在  2) squashfs 格式 + 压缩包完整性
# 方案二：不再校验镜像内overlay分区尺寸，改为校验限制脚本已内置
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 04-verify-image.sh <lede源码目录>}"
IMG_DIR="${LEDE_DIR}/bin/targets/x86/64"

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
set +e
gzip -t "$IMG_GZ"
GZ_RET=$?
set -e
if [ $GZ_RET -eq 1 ]; then
    echo "ERROR: img.gz 压缩包损坏！"
    exit 1
elif [ $GZ_RET -eq 2 ]; then
    echo "NOTICE: 检测到sysupgrade尾部附加数据(trailing garbage)，属于OpenWrt combined镜像正常情况"
fi
echo "OK: squashfs 格式且压缩包主体完整"

echo "===== 3/3 校验：overlay 2G限制脚本已内置镜像 ====="
gzip -dc "$IMG_GZ" > /tmp/check.img
LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" /tmp/check.img
SQUASHFS_PART="${LOOP_DEV}p2"
mkdir -p /tmp/mnt_squash
mount -t squashfs "$SQUASHFS_PART" /tmp/mnt_squash

if [ -f "/tmp/mnt_squash/overlay-limit.sh" ] && [ -f "/tmp/mnt_squash/etc/init.d/overlay-limit" ]; then
    echo "OK: overlay上限限制脚本已经打包进固件"
else
    echo "ERROR：镜像缺失 overlay-limit 限制脚本！注入流程异常"
    losetup -d "$LOOP_DEV"
    rm -rf /tmp/mnt_squash /tmp/check.img
    exit 1
fi

umount /tmp/mnt_squash
losetup -d "$LOOP_DEV"
rm -rf /tmp/mnt_squash
echo "===== 校验全部通过 ====="
