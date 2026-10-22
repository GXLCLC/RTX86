#!/bin/bash
# =====================================================================
# 06-preconfig.sh —— 固件插件默认配置（仅首次开机生效，不覆盖用户后续配置）
# 职责：新增插件配置初始化统一入口，只做配置层，不负责拉取插件
#  1. mwan3：清空预设成员/策略/规则，界面显示「尚未配置任何接口」
#     （mwan3 包自带 /etc/config/mwan3 默认配置含 wan/wan6/wanb/wanb6 多接口示例，
#      不清理会导致 mwan3 接管流量、网络不稳定）
#  2. smartdns：默认禁用，关闭开机自启（默认配置 enabled=1 会抢占 DNS 通道，
#     与 AdGuardHome 重定向冲突）
#  3. ttyd：明确端口 7681 / 监听 @lan + 防火墙放行 lan 访问
# 注入机制（双通道，互为备份）：
#   A. files/etc/init.d/zz-preconfig-fix（START=99，标记文件 /etc/preconfig-applied 防重复）
#      —— init.d 为 03b 实锤有效机制，每次启动检查、仅首次执行清理
#   B. files/etc/uci-defaults/99-preconfig-init（boot 的 uci_apply_defaults 首次执行）
#      —— 传统 uci-defaults 通道，作备用；成功后自动删除
# 后续新增插件默认配置均追加本脚本，保持拉包/配置职责分离
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 06-preconfig.sh <lede源码目录>}"

echo -e "\n>> ====== 开始预置插件默认配置（init.d + uci-defaults 双通道）======"

# ---------- 前置校验：源码目录必须存在 ----------
if [ ! -d "${LEDE_DIR}" ]; then
    echo "ERROR: 源码目录不存在 -> ${LEDE_DIR}"
    echo "修复建议：检查传入的 lede 源码路径是否正确"
    exit 1
fi

# ==================== 通道A：init.d 兜底脚本（主通道） ====================
mkdir -p "${LEDE_DIR}/files/etc/init.d"
cat > "${LEDE_DIR}/files/etc/init.d/zz-preconfig-fix" <<'INIT_SCRIPT'
#!/bin/sh /etc/rc.common
# 预置配置兜底：仅首次启动执行一次（标记文件防重复，避免覆盖用户后续配置）
START=99
STOP=90

start() {
    [ -f /etc/preconfig-applied ] && return 0

    logger -t preconfig "开始应用首次开机预置配置"

    # 1. mwan3：删除包自带默认配置（含 wan/wan6/wanb/wanb6 多接口示例），回到空白无接口状态
    rm -f /etc/config/mwan3
    /etc/init.d/mwan3 reload >/dev/null 2>&1 || true

    # 2. smartdns：默认禁用 + 停止服务 + 关闭自启（释放 DNS 通道给 AdGuardHome）
    uci -q set smartdns.@smartdns[0].enabled='0' 2>/dev/null || true
    uci -q commit smartdns 2>/dev/null || true
    /etc/init.d/smartdns disable >/dev/null 2>&1 || true
    /etc/init.d/smartdns stop >/dev/null 2>&1 || true

    # 3. ttyd：明确端口/监听 + 防火墙放行 lan 访问 7681
    uci -q set ttyd.@ttyd[0].port='7681' 2>/dev/null || true
    uci -q set ttyd.@ttyd[0].interface='@lan' 2>/dev/null || true
    uci -q set ttyd.@ttyd[0].command='/bin/login' 2>/dev/null || true
    uci -q commit ttyd 2>/dev/null || true
    if ! uci -q get firewall.ttyd >/dev/null 2>&1; then
        uci add firewall rule >/dev/null
        uci set firewall.@rule[-1].name='ttyd'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].proto='tcp'
        uci set firewall.@rule[-1].dest_port='7681'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1 || true
    fi
    /etc/init.d/ttyd enable >/dev/null 2>&1 || true
    /etc/init.d/ttyd restart >/dev/null 2>&1 || true

    touch /etc/preconfig-applied
    logger -t preconfig "预置配置完成：mwan3 空白 / smartdns 禁用 / ttyd 7681 已放行"
}

stop() {
    return 0
}
INIT_SCRIPT
chmod +x "${LEDE_DIR}/files/etc/init.d/zz-preconfig-fix"
echo ">> ✅ [通道A] files/etc/init.d/zz-preconfig-fix 已写入（START=99，标记防重）"

# ==================== 通道B：uci-defaults 快速路径（备用通道） ====================
mkdir -p "${LEDE_DIR}/files/etc/uci-defaults"
cat > "${LEDE_DIR}/files/etc/uci-defaults/99-preconfig-init" <<'UCI_SCRIPT'
#!/bin/sh
# 与 zz-preconfig-fix 逻辑保持一致：mwan3 空白 / smartdns 禁用 / ttyd 7681 放行
# 由 /etc/init.d/boot 的 uci_apply_defaults 在首次开机执行，成功后自动删除。
# 所有 uci 操作均带 -q 与兜底，避免 section 不存在时中断启动流程。
rm -f /etc/config/mwan3
uci -q set smartdns.@smartdns[0].enabled='0' 2>/dev/null || true
uci -q commit smartdns 2>/dev/null || true
/etc/init.d/smartdns disable >/dev/null 2>&1 || true
uci -q set ttyd.@ttyd[0].port='7681' 2>/dev/null || true
uci -q set ttyd.@ttyd[0].interface='@lan' 2>/dev/null || true
uci -q commit ttyd 2>/dev/null || true
if ! uci -q get firewall.ttyd >/dev/null 2>&1; then
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='ttyd'
    uci set firewall.@rule[-1].src='lan'
    uci set firewall.@rule[-1].proto='tcp'
    uci set firewall.@rule[-1].dest_port='7681'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
fi
/etc/init.d/ttyd enable >/dev/null 2>&1 || true
exit 0
UCI_SCRIPT
chmod +x "${LEDE_DIR}/files/etc/uci-defaults/99-preconfig-init"
echo ">> ✅ [通道B] files/etc/uci-defaults/99-preconfig-init 已写入（首次开机快速路径）"

echo ">> 预置配置注入完成：mwan3 空白 / smartdns 禁用 / ttyd 7681 + 防火墙放行"
echo ">> ==========================================="
