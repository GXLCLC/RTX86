#!/bin/bash
# =====================================================================
# 05-release-body.sh —— 生成 Release 说明
# 内容：默认信息 / 内核版本 / 固件版本 / 纯净插件清单（不展示 kmod）
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 05-release-body.sh <lede源码目录>}"
OUT="release_body.md"

KERNEL_VER=$(grep -E "^KERNEL_PATCHVER" "${LEDE_DIR}/include/kernel-version.mk" \
             | head -n1 | awk '{print $3}')
FIRMWARE_VER="$(date +%Y%m%d)-$(git -C "${LEDE_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

cat > "$OUT" <<EOF
# LEDE X86_64 固件（squashfs）

## 🖥️ 默认信息
| 项目 | 值 |
|---|---|
| 后台地址 | http://192.168.2.1 |
| 默认密码 | 12345678 |
| 时区 | Asia/Shanghai |
| 默认主题 | Argon |
| 镜像格式 | squashfs-combined-efi（img.gz） |

## 🧩 版本信息
- **内核版本**：${KERNEL_VER}
- **固件版本**：${FIRMWARE_VER}
- **架构**：X86_64 Generic

## 📦 预装插件清单（纯净版，不含 kmod）
EOF

# 纯净插件清单：仅列出 luci-app / luci-theme，过滤全部 kmod
grep -E "^CONFIG_PACKAGE_(luci-app|luci-theme)-.+.=y" "${LEDE_DIR}/.config" \
    | sed -E 's/^CONFIG_PACKAGE_(.+)=y$/- \1/' >> "$OUT"

echo ">> Release 说明已生成：$OUT"
