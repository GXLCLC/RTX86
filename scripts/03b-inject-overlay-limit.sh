#!/bin/bash
# 03b-inject-overlay-limit.sh
# 作用：注入overlay最大2G限制脚本与开机服务，方案二配套
set -e
LEDE_DIR="${1:?用法: $0 <lede源码目录>}"

# 创建files目录（Lean的files目录，内容直接打包进固件）
mkdir -p "${LEDE_DIR}/files/etc/init.d"

# 写入 overlay-limit.sh
cat > "${LEDE_DIR}/files/overlay-limit.sh" <<'EOF'
#!/bin/sh
MAX_MB=2048
MARK_FILE="/etc/overlay-limit-done"

if [ -f "$MARK_FILE" ]; then
    exit 0
fi

OVERLAY_MOUNT=$(mount | awk '/overlay/ && $3=="/overlay" {print $1}')
if [ -z "$OVERLAY_MOUNT" ]; then
    echo "未识别overlay挂载，跳过限制"
    touch "$MARK_FILE"
    exit 0
fi

OVERLAY_DEV=$(readlink -f "$OVERLAY_MOUNT")
if [ ! -b "$OVERLAY_DEV" ]; then
    echo "overlay不是块设备，跳过"
    touch "$MARK_FILE"
    exit 0
fi

MAX_SECTORS=$(( MAX_MB * 2048 ))
CUR_SECTORS=$(blockdev --getsize "$OVERLAY_DEV")

if [ "$CUR_SECTORS" -gt "$MAX_SECTORS" ]; then
    echo "限制overlay文件系统上限 ${MAX_MB}MB"
    resize2fs "$OVERLAY_DEV" ${MAX_SECTORS}
fi

touch "$MARK_FILE"
EOF

# 写入procd开机服务
cat > "${LEDE_DIR}/files/etc/init.d/overlay-limit" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=0
USE_PROCD=1
start_service() {
    /overlay-limit.sh
}
EOF

# 赋予执行权限
chmod +x "${LEDE_DIR}/files/overlay-limit.sh"
chmod +x "${LEDE_DIR}/files/etc/init.d/overlay-limit"

echo ">> overlay 2G限制脚本注入完成"
