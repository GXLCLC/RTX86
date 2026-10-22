#!/bin/bash
# =====================================================================
# 01-custom-settings.sh —— 自定义密码 / 主机名 / 后台 IP / 时区
# 工作流拉取 lean 源码后立即执行，直接替换源码内的默认配置文件
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 01-custom-settings.sh <lede源码目录>}"

# ---------- 默认参数（无人值守全自动配置）----------
DEFAULT_LAN_IP="192.168.2.1"     # 默认后台 IP
DEFAULT_PASSWORD=""              # 默认密码（空 = 无密码直接登录）
DEFAULT_HOSTNAME="LEDE-X86"      # 默认主机名

DEFAULT_SETTINGS="${LEDE_DIR}/package/lean/default-settings/files/zzz-default-settings"
SHADOW_FILE="${LEDE_DIR}/package/base-files/files/etc/shadow"
BOARD_NETWORK="${LEDE_DIR}/package/base-files/files/etc/board.d/99-default_network"

# ---------- 前置校验：关键配置文件必须存在，异常直接终止并给出修复建议 ----------
for f in "$DEFAULT_SETTINGS" "$SHADOW_FILE" "$BOARD_NETWORK"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: 关键配置文件不存在 -> $f"
        echo "修复建议：lean master 分支目录结构可能已调整，请核对源码路径"
        exit 1
    fi
done

# ---------- 1. 默认后台 IP：board.d 生成阶段直接写入 ----------
# 背景：Lean 新版已无静态 /etc/config/network，lan 由 board.d/99-default_network 的
# ucidef_set_interface_lan 'eth0' 动态生成（默认 192.168.1.1）；
# 旧脚本 sed 192.168.1.1 匹配不到任何内容（zzz 里根本没有 IP 设置），已废弃。
# ucidef_set_interface 支持任意 key-value，直接传 ipaddr 覆盖默认值；
# board.d 在 preinit 阶段执行，早于一切 uci-defaults，是最早生效的层级。
sed -i "s|ucidef_set_interface_lan 'eth0'|ucidef_set_interface \"lan\" device \"eth0\" protocol \"static\" ipaddr \"${DEFAULT_LAN_IP}\"|" "$BOARD_NETWORK"
if ! grep -q "ipaddr \"${DEFAULT_LAN_IP}\"" "$BOARD_NETWORK"; then
    echo "ERROR: board.d IP 注入失败，sed 未匹配到 ucidef_set_interface_lan 'eth0'"
    echo "修复建议：检查 99-default_network 中 lan 定义是否被上游调整"
    exit 1
fi

# ---------- 2. 密码：shadow root 密码字段置空（无密码） ----------
# 同时必须删除 zzz-default-settings（安装为 /etc/uci-defaults/99-default-settings）
# 中 Lean 的密码固化 sed 行：它专门匹配空密码 root 并替换成 Lean 默认哈希，
# 不删除则"无密码"会被静默覆盖
sed -i '/V4UetPzk/d' "$DEFAULT_SETTINGS"
if [ -n "$DEFAULT_PASSWORD" ]; then
    PASSWORD_HASH=$(openssl passwd -1 "$DEFAULT_PASSWORD")
    sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH//&/\\&}:|" "$SHADOW_FILE"
else
    sed -i "s|^root:[^:]*:|root::|" "$SHADOW_FILE"
fi
grep -q '^root::' "$SHADOW_FILE" || { echo "ERROR: shadow 密码置空失败"; exit 1; }

# ---------- 3. 主机名 + 时区固化 Asia/Shanghai + IP 兜底（注入首次开机脚本）----------
cat >> "$DEFAULT_SETTINGS" <<EOF

# ===== 云编译自动注入：主机名 / 时区固化 =====
uci set system.@system[0].hostname='${DEFAULT_HOSTNAME}'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system

# ===== 云编译自动注入：后台 IP 双保险（board.d 已生成，此处兜底覆盖）=====
uci set network.lan.ipaddr='${DEFAULT_LAN_IP}'
uci commit network
EOF

echo ">> 自定义配置完成：IP=${DEFAULT_LAN_IP}（board.d 生成 + uci-defaults 兜底）/ 密码=${DEFAULT_PASSWORD:-无密码} / 主机名=${DEFAULT_HOSTNAME} / 时区=Asia/Shanghai"
