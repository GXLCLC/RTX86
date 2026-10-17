#!/bin/bash
# ============================================================
# package_firmware.sh - 打包时间戳固件 + 清理多余镜像
# 用法: bash scripts/package_firmware.sh <bin目录> <输出目录>
# 产物: YYYYMMDD-HHMMSS-lede-x86_64-squashfs.img.gz（时区 Asia/Shanghai）
# 判定: 目标 img.gz 未生成 -> 直接判定编译失败，退出码 1（不创建 Release）
# 清理: bin 目录其余镜像（vdi/vmdk/vhdx/qcow2/efi 等）全部自动删除
# ============================================================
set -euo pipefail

BIN_DIR="${1:?用法: bash scripts/package_firmware.sh <bin目录> <输出目录>}"
OUT_DIR="${2:-output}"

TS=$(date +%Y%m%d-%H%M%S)                                   # 时间戳前缀
FW_NAME="${TS}-lede-x86_64-squashfs.img.gz"                 # 固件文件名
SRC_GZ="$BIN_DIR/openwrt-x86-64-generic-squashfs-sysupgrade.img.gz"

echo "==> [1/4] 目标镜像生成判定"
if [ ! -f "$SRC_GZ" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: $SRC_GZ 未生成，判定编译失败，不创建 Release"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi
ls -lh "$SRC_GZ"

echo "==> [2/4] 生成时间戳固件: $FW_NAME"
mkdir -p "$OUT_DIR"
cp "$SRC_GZ" "$OUT_DIR/$FW_NAME"
(cd "$OUT_DIR" && sha256sum "$FW_NAME" > "${FW_NAME}.sha256")
ls -lh "$OUT_DIR"

# 将时间戳标签写入 GITHUB_ENV，供后续 Release 步骤使用
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RELEASE_TAG=$TS" >> "$GITHUB_ENV"
  echo "FW_NAME=$FW_NAME" >> "$GITHUB_ENV"
fi

echo "==> [3/4] 清理 bin 目录多余镜像（仅保留 squashfs sysupgrade）"
cd "$BIN_DIR"
# 删除所有镜像类文件，仅保留 squashfs sysupgrade img/img.gz
find . -maxdepth 1 -type f \( \
  -name "*.img" -o -name "*.img.gz" -o \
  -name "*.vdi" -o -name "*.vdi.gz" -o \
  -name "*.vmdk" -o -name "*.vmdk.gz" -o \
  -name "*.vhdx" -o -name "*.vhdx.gz" -o \
  -name "*.qcow2" -o -name "*.iso" -o \
  -name "*.efi" -o -name "*.vhd" \) \
  ! -name "openwrt-x86-64-generic-squashfs-sysupgrade.img" \
  ! -name "openwrt-x86-64-generic-squashfs-sysupgrade.img.gz" \
  -print -delete
# 删除子目录中残留的镜像文件
find . -mindepth 2 -type f \( -name "*.vdi" -o -name "*.vmdk" -o -name "*.vhdx" -o -name "*.qcow2" \) -delete 2>/dev/null || true
echo "清理后 bin 目录内容:"
ls -lh

echo "==> [4/4] 完成: $OUT_DIR/$FW_NAME"
