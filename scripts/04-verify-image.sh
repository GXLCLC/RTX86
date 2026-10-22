#!/bin/bash
# =====================================================================
# 04-verify-image.sh —— 编译产物自动校验
# 校验：1) 目标镜像存在  2) squashfs 格式 + 压缩包完整性
# 方案二：不再校验镜像内overlay分区尺寸，改为校验限制脚本已内置
# 附加：4) 预置配置双通道文件(zz-preconfig-fix/99-preconfig-init)已打包
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
CHECK_IMG=/tmp/check.img
MNT_DIR=/tmp/mnt_squash
LOOP_DEV=""

# 无论成功失败，退出前自动清理：卸载 -> detach loop -> 删临时文件
cleanup() {
  sudo umount "$MNT_DIR" 2>/dev/null || true
  if [ -n "$LOOP_DEV" ]; then
    sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi
  rm -f "$CHECK_IMG"
  rmdir "$MNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# gzip -dc 对带 trailing garbage 的 combined 镜像同样返回 2（warning），
# 解压数据完整；必须先关闭 set -e 再按退出码分流，
# 否则脚本在 set -e 下被 gzip 的 warning 退出码直接终止（历史事故根因）
set +e
gzip -dc "$IMG_GZ" > "$CHECK_IMG"
GZ_RET=$?
set -e
if [ $GZ_RET -eq 1 ]; then
  echo "ERROR: 镜像解压失败！"
  exit 1
elif [ $GZ_RET -eq 2 ]; then
  echo "NOTICE: 检测到sysupgrade尾部附加数据(trailing garbage)，属于OpenWrt combined镜像正常情况"
fi
echo "OK: 镜像解压完成（$(du -h "$CHECK_IMG" | cut -f1)）"

# combined-efi 镜像为 GPT 磁盘：p1=EFI引导分区，p2=squashfs根分区
# -P 必须显式指定：不加则不扫描分区表，${LOOP_DEV}p2 设备节点不会生成
# losetup/mount 需要 root：GitHub Actions runner 默认非 root，统一走 sudo
LOOP_DEV=$(sudo losetup --show -Pf "$CHECK_IMG")
echo "loop 设备：$LOOP_DEV"
SQUASHFS_PART="${LOOP_DEV}p2"
if [ ! -b "$SQUASHFS_PART" ]; then
  echo "ERROR: 分区 $SQUASHFS_PART 不存在，镜像分区布局异常"
  echo "修复建议：用 sudo fdisk -l $CHECK_IMG 查看实际分区布局"
  exit 1
fi
FS_TYPE=$(sudo blkid -o value -s TYPE "$SQUASHFS_PART" 2>/dev/null || echo "未知")
echo "根分区 $SQUASHFS_PART 文件系统：$FS_TYPE"
if [ "$FS_TYPE" != "squashfs" ]; then
  echo "ERROR: 根分区不是 squashfs 格式"
  exit 1
fi

sudo modprobe squashfs 2>/dev/null || true
mkdir -p "$MNT_DIR"
sudo mount -t squashfs "$SQUASHFS_PART" "$MNT_DIR"

if [ -f "$MNT_DIR/overlay-limit.sh" ] && [ -f "$MNT_DIR/etc/init.d/overlay-limit" ]; then
  echo "OK: overlay上限限制脚本已经打包进固件"
else
  echo "ERROR：镜像缺失 overlay-limit 限制脚本！注入流程异常"
  echo "修复建议：检查 scripts/03b-inject-overlay-limit.sh 是否正确写入 lede/files/ 目录"
  exit 1
fi

# 4/4 校验：预置配置双通道文件已打包进固件（防止 files/ 注入静默丢失）
if [ -f "$MNT_DIR/etc/init.d/zz-preconfig-fix" ] || [ -f "$MNT_DIR/etc/uci-defaults/99-preconfig-init" ]; then
  echo "OK: 预置配置通道文件已打包进固件"
  [ -f "$MNT_DIR/etc/init.d/zz-preconfig-fix" ] && echo "  - zz-preconfig-fix(init.d) 在镜像中"
  [ -f "$MNT_DIR/etc/uci-defaults/99-preconfig-init" ] && echo "  - 99-preconfig-init(uci-defaults) 在镜像中"
else
  echo "ERROR：镜像缺失预置配置文件（zz-preconfig-fix / 99-preconfig-init）！"
  echo "修复建议：检查 scripts/06-preconfig.sh 是否正确写入 lede/files/ 目录"
  exit 1
fi

sudo umount "$MNT_DIR"
echo "===== 校验全部通过 ====="
