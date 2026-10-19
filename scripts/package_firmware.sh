#!/bin/bash
# ============================================================
# package_firmware.sh - 打包时间戳固件 + 清理多余镜像
# 用法: bash scripts/package_firmware.sh <bin目录> <输出目录>
# 产物: YYYYMMDD-HHMMSS-lede-x86_64-squashfs.img.gz（时区 Asia/Shanghai）
# 判定: 未发现任何可发布的磁盘镜像 -> 直接判定编译失败，退出码 1（不创建 Release）
# 清理: bin 目录其余镜像（rootfs/vdi/vmdk/vhdx/qcow2/efi 等）全部自动删除
#
# 镜像定位说明（run 12 实证，勿改回 sysupgrade 硬编码名）:
#   lean x86_64 目标只产出 combined(.efi).img(.gz) 与 rootfs.img(.gz)，
#   target/linux/x86/image/Makefile 无任何 sysupgrade 目标
#   （沙箱 grep + GitHub live API 双重确认 sysupgrade 出现次数: 0）。
#   默认镜像配置 GRUB_EFI_IMAGES=y / GRUB_IMAGES=n / TARGET_IMAGES_GZIP=y，
#   实际交付镜像 = openwrt-x86-64-generic-squashfs-combined-efi.img.gz
#   （GPT + EFI，p1 kernel FAT + p2 rootfs 2048MiB squashfs）。
#   候选顺序: combined-efi > combined > glob 兜底 > sysupgrade 兼容名；
#   仅有未压缩 .img 时（TARGET_IMAGES_GZIP=n）现场 gzip 压缩。
# ============================================================
set -euo pipefail

BIN_DIR="${1:?用法: bash scripts/package_firmware.sh <bin目录> <输出目录>}"
OUT_DIR="${2:-output}"

TS=$(date +%Y%m%d-%H%M%S)                                   # 时间戳前缀
FW_NAME="${TS}-lede-x86_64-squashfs.img.gz"                 # 固件文件名
cd "$BIN_DIR"

echo "==> [1/4] 目标镜像生成判定（候选: combined-efi > combined > glob 兜底 > sysupgrade 兼容名）"
SRC_GZ=""
for cand in \
  openwrt-x86-64-generic-squashfs-combined-efi.img.gz \
  openwrt-x86-64-generic-squashfs-combined.img.gz \
  $(ls *-squashfs-combined*.img.gz 2>/dev/null || true) \
  openwrt-x86-64-generic-squashfs-sysupgrade.img.gz; do
  if [ -f "$cand" ]; then
    SRC_GZ="$cand"
    break
  fi
done

SRC_IMG=""
if [ -z "$SRC_GZ" ]; then
  # 无 .gz 成品（TARGET_IMAGES_GZIP=n 时）: 回退未压缩 .img，后续现场压缩
  for cand in \
    openwrt-x86-64-generic-squashfs-combined-efi.img \
    openwrt-x86-64-generic-squashfs-combined.img \
    $(ls *-squashfs-combined*.img 2>/dev/null || true) \
    openwrt-x86-64-generic-squashfs-sysupgrade.img; do
    if [ -f "$cand" ]; then
      SRC_IMG="$cand"
      break
    fi
  done
fi

if [ -z "$SRC_GZ" ] && [ -z "$SRC_IMG" ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: 未找到任何可发布的磁盘镜像，判定编译失败，不创建 Release"
  echo "bin 目录实际内容:"
  ls -lh
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi

if [ -n "$SRC_GZ" ]; then
  echo "发现成品镜像: $SRC_GZ"
  gzip -t "$SRC_GZ" || { echo "错误: $SRC_GZ gzip 结构损坏，判定编译失败"; exit 1; }
  ls -lh "$SRC_GZ"
else
  echo "未发现 .gz 成品，从未压缩镜像现场压缩: $SRC_IMG"
  ls -lh "$SRC_IMG"
fi

echo "==> [2/4] 生成时间戳固件: $FW_NAME"
mkdir -p "$OUT_DIR"
if [ -n "$SRC_GZ" ]; then
  cp "$SRC_GZ" "$OUT_DIR/$FW_NAME"
else
  gzip -c "$SRC_IMG" > "$OUT_DIR/$FW_NAME"
fi
(cd "$OUT_DIR" && sha256sum "$FW_NAME" > "${FW_NAME}.sha256")
ls -lh "$OUT_DIR"

# 将时间戳标签写入 GITHUB_ENV，供后续 Release 步骤使用
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RELEASE_TAG=$TS" >> "$GITHUB_ENV"
  echo "FW_NAME=$FW_NAME" >> "$GITHUB_ENV"
fi

echo "==> [3/4] 清理 bin 目录多余镜像（仅保留本次打包源镜像）"
KEEP="${SRC_GZ:-$SRC_IMG}"
# 删除所有镜像类文件，仅保留打包源（combined-efi/combined/sysupgrade）
find . -maxdepth 1 -type f \( \
  -name "*.img" -o -name "*.img.gz" -o \
  -name "*.vdi" -o -name "*.vdi.gz" -o \
  -name "*.vmdk" -o -name "*.vmdk.gz" -o \
  -name "*.vhdx" -o -name "*.vhdx.gz" -o \
  -name "*.qcow2" -o -name "*.iso" -o \
  -name "*.efi" -o -name "*.vhd" \) \
  ! -name "$KEEP" \
  -print -delete
# 删除子目录中残留的镜像文件
find . -mindepth 2 -type f \( -name "*.vdi" -o -name "*.vmdk" -o -name "*.vhdx" -o -name "*.qcow2" \) -delete 2>/dev/null || true
echo "清理后 bin 目录内容:"
ls -lh

echo "==> [4/4] 完成: $OUT_DIR/$FW_NAME"
