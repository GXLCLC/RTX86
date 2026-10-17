#!/bin/bash
# ============================================================
# custom_settings.sh - 自定义系统默认参数
# 用法: bash scripts/custom_settings.sh <源码目录>
# 功能: 后台IP / 登录密码 / 主机名 / 时区 / 默认主题
# 说明: 独立脚本，工作流直接调用，修改 yml 不影响本脚本
# ============================================================
set -euo pipefail

SRC="${1:-lede}"          # 源码目录（默认 lede）
cd "$SRC"

echo "==> [1/6] 默认后台 IP: 192.168.2.1"
# config_generate 首次启动时生成网络配置，替换默认 192.168.1.1
sed -i 's/192\.168\.1\.1/192.168.2.1/g' package/base-files/files/bin/config_generate
# 预置网络配置文件同步替换（双保险）
if [ -f package/base-files/files/etc/config/network ]; then
  sed -i "s/option ipaddr '192\.168\.1\.1'/option ipaddr '192.168.2.1'/" \
    package/base-files/files/etc/config/network
fi
grep -n "192.168.2.1" package/base-files/files/bin/config_generate | head -3 || true

echo "==> [2/6] 后台登录密码: 12345678"
# 生成 MD5-CRYPT 密码哈希，写入 shadow（OpenWrt login 支持 $1$ 前缀）
PWD_HASH=$(openssl passwd -1 "12345678")
sed -i "s#^root:[^:]*:#root:${PWD_HASH}:#" package/base-files/files/etc/shadow
grep "^root:" package/base-files/files/etc/shadow

echo "==> [3/6] 主机名: OpenWrt"
echo "OpenWrt" > package/base-files/files/etc/hostname
# lean 源码的 package/base-files/files/etc/ 下没有 config/ 目录
# （默认 uci 配置由首次启动的 board.d/config_generate 运行时生成），
# 因此此处对 etc/config/system 做存在性处理: 存在则替换, 不存在则创建最小配置
SYSTEM_CFG="package/base-files/files/etc/config/system"
if [ -f "$SYSTEM_CFG" ]; then
  sed -i "s/option hostname '.*'/option hostname 'OpenWrt'/" "$SYSTEM_CFG"
  grep -q "option hostname" "$SYSTEM_CFG" || \
    sed -i "/^config system/a\	option hostname 'OpenWrt'" "$SYSTEM_CFG"
else
  mkdir -p package/base-files/files/etc/config
  cat > "$SYSTEM_CFG" <<'EOF'
config system
	option hostname 'OpenWrt'
	option zonename 'Asia/Shanghai'
	option timezone 'CST-8'
EOF
  echo "    已创建 $SYSTEM_CFG（lean 源码默认不含该文件，此处补齐最小配置）"
fi
grep "hostname" "$SYSTEM_CFG"

echo "==> [4/6] 时区: Asia/Shanghai"
# 上一步已保证 $SYSTEM_CFG 存在，此处直接替换 zonename
sed -i "s/option zonename '.*'/option zonename 'Asia\/Shanghai'/" "$SYSTEM_CFG"
grep -q "option zonename" "$SYSTEM_CFG" || \
  sed -i "/^config system/a\	option zonename 'Asia/Shanghai'" "$SYSTEM_CFG"
echo "CST-8" > package/base-files/files/etc/TZ # POSIX TZ（busybox 生效）

echo "==> [5/6] 默认 LuCI 主题: Argon"
# 直接改 luci-base 的默认配置（编译期生效）
LUCI_CFG="feeds/luci/modules/luci-base/root/etc/config/luci"
if [ -f "$LUCI_CFG" ]; then
  sed -i "s#option mediaurlbase .*#option mediaurlbase '/luci-static/argon'#" "$LUCI_CFG"
  grep "mediaurlbase" "$LUCI_CFG" || true
else
  echo "提示: 未找到 $LUCI_CFG，将由 uci-defaults 兜底设置"
fi

echo "==> [6/6] 写入 uci-defaults 兜底脚本（首次启动强制执行）"
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-rtx86-settings <<'EOF'
#!/bin/sh
# RTX86 默认参数兜底：主题 Argon + 时区 Asia/Shanghai
uci set luci.main.mediaurlbase='/luci-static/argon' 2>/dev/null
uci commit luci 2>/dev/null
uci set system.@system[0].zonename='Asia/Shanghai' 2>/dev/null
uci set system.@system[0].hostname='OpenWrt' 2>/dev/null
uci commit system 2>/dev/null
exit 0
EOF
chmod 755 package/base-files/files/etc/uci-defaults/99-rtx86-settings

echo "==> 自定义系统参数应用完成（IP=192.168.2.1 / 密码=12345678 / 主题=Argon / 时区=Asia/Shanghai）"
