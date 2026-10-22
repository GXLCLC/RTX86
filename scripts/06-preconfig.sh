#!/bin/bash
# =====================================================================
# 06-preconfig.sh —— 固件插件默认配置（首次开机 uci-defaults 注入）
# 职责：新增插件配置初始化统一入口，只做配置层，不负责拉取插件
#  1. mwan3：清空预设成员/策略/规则，界面显示「尚未配置任何接口」
#  2. smartdns：默认禁用，关闭开机自启
# 后续新增插件默认配置均追加本脚本，保持拉包/配置职责分离
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 06-preconfig.sh <lede源码目录>}"

echo -e "\n>> ====== 开始预置插件默认配置（uci-defaults）======"

# ---------- 前置校验：源码目录必须存在 ----------
if [ ! -d "${LEDE_DIR}" ]; then
    echo "ERROR: 源码目录不存在 -> ${LEDE_DIR}"
    echo "修复建议：检查传入的 lede 源码路径是否正确"
    exit 1
fi

# ---------- 建立首次开机脚本目录 ----------
mkdir -p "${LEDE_DIR}/files/etc/uci-defaults"

# ---------- 写入首次开机初始化脚本 ----------
cat > "${LEDE_DIR}/files/etc/uci-defaults/99-preconfig-init" <<'UCI_SCRIPT'
#!/bin/sh
# 1. mwan3：清空全部预设成员/策略/规则，回到空白无接口状态
uci batch <<EOF
delete mwan3
commit mwan3
EOF

# 2. smartdns：设置为禁用，关闭开机自启
uci set smartdns.@smartdns[0].enabled='0'
uci commit smartdns
/etc/init.d/smartdns disable

exit 0
UCI_SCRIPT

chmod +x "${LEDE_DIR}/files/etc/uci-defaults/99-preconfig-init"

echo ">> ✅ 插件默认配置注入完成：mwan3 清空为空白 / smartdns 默认禁用"
echo ">> ==========================================="
