#!/bin/bash
# =====================================================================
# 03-conflict-fix.sh —— 依赖冲突处理
# 策略：保留 lean 官方内核；仅移除与官方内核冲突的第三方模块；
#       剔除一切外部预编译 kmod，保证内核模块与本机编译内核严格匹配
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 03-conflict-fix.sh <lede源码目录>}"

# ---------- 1. TurboACC：移除 SFE / Shortcut-FE，仅保留流量分载 / 全锥形NAT / BBR ----------
echo ">> 移除 SFE / Shortcut-FE 冲突模块（保留流量分载 / 全锥形NAT / BBR）"
find "${LEDE_DIR}/package" -maxdepth 3 -type d \( \
    -iname "*shortcut*" -o -iname "*sfe*" \) | while read -r d; do
    echo "   - 移除：$d"
    rm -rf "$d"
done

# ---------- 2. 剔除第三方源携带的外部预编译 kmod（.ipk 成品）----------
# 说明：以源码形式随固件一起编译的内核模块（如 kmod-oaf）与官方内核严格匹配，予以保留
find "${LEDE_DIR}/package/small-package" "${LEDE_DIR}/package/kenzok8-packages" \
    -type f -name "*.ipk" -delete 2>/dev/null || true

# ---------- 3. 复核：确认无 SFE 残留 ----------
if find "${LEDE_DIR}/package" \( -iname "*shortcut*" -o -iname "*sfe*" \) | grep -q .; then
    echo "ERROR: 仍存在 SFE/Shortcut-FE 残留，请人工检查"
    exit 1
fi
echo ">> 冲突处理完成：官方内核保留，冲突模块已移除，无外部预编译 kmod"
