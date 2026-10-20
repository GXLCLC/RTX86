#!/bin/bash
# =====================================================================
# 01-custom-settings.sh —— 自定义密码 / 主机名 / 后台 IP / 时区
# 工作流拉取 lean 源码后立即执行，直接替换源码内的默认配置文件
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 01-custom-settings.sh <lede源码目录>}"

# ---------- 默认参数（无人值守全自动配置）----------
DEFAULT_LAN_IP="192.168.2.1"     # 默认后台 IP
DEFAULT_PASSWORD="12345678"      # 默认密码
DEFAULT_HOSTNAME="LEDE-X86"      # 默认主机名

DEFAULT_SETTINGS="${LEDE_DIR}/package/lean/default-settings/files/zzz-default-settings"
SHADOW_FILE="${LEDE_DIR}/package/base-files/files/etc/shadow"

# ---------- 前置校验：关键配置文件必须存在，异常直接终止并给出修复建议 ----------
for f in "$DEFAULT_SETTINGS" "$SHADOW_FILE"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: 关键配置文件不存在 -> $f"
        echo "修复建议：lean master 分支目录结构可能已调整，请核对源码路径"
        exit 1
    fi
done

# ---------- 1. 默认后台 IP：192.168.1.1 -> 192.168.2.1 ----------
sed -i "s/192\.168\.1\.1/${DEFAULT_LAN_IP}/g" "$DEFAULT_SETTINGS"

# ---------- 2. 默认密码：生成哈希后直接写入 shadow（构建期固化，运行期无交互）----------
PASSWORD_HASH=$(openssl passwd -1 "$DEFAULT_PASSWORD")
sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH//&/\\&}:|" "$SHADOW_FILE"

# ---------- 3. 主机名 + 时区固化 Asia/Shanghai（注入首次开机脚本）----------
cat >> "$DEFAULT_SETTINGS" <<EOF

# ===== 云编译自动注入：主机名 / 时区固化 =====
uci set system.@system[0].hostname='${DEFAULT_HOSTNAME}'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit system
EOF

echo ">> 自定义配置完成：IP=${DEFAULT_LAN_IP} / 密码已固化 / 主机名=${DEFAULT_HOSTNAME} / 时区=Asia/Shanghai"
