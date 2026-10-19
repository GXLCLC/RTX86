#!/bin/bash
# ============================================================
# verify_ustream_variants.sh - 编译前校验 ustream-ssl 变体唯一性
# 用法: bash scripts/verify_ustream_variants.sh <源码目录>
#
# 背景（run 11 实证，编译约 2.5 小时后失败）:
#   ustream-ssl 的 Makefile 显式覆盖了 PKG_BUILD_DIR——
#       PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_SOURCE_SUBDIR)
#   而 lean include/package.mk 第 11 行的默认值本可按 BUILD_VARIANT
#   为每个变体隔离构建目录（$(BUILD_DIR)/ustream-ssl-<variant>/...）。
#   覆盖之后，mbedtls / openssl / wolfssl 三个变体共享同一构建目录：
#   先构建的变体把 CMakeCache（如 -DMBEDTLS=ON 对应的缓存项）与编译
#   产物留在共享目录，后构建的变体直接复用，最终打包出链接错误 SSL
#   库的 .so，ipkg 依赖检查必然失败：
#       Package libustream-openssl is missing dependencies for the
#       following libraries:
#       libmbedcrypto.so.16  libmbedtls.so.21  libmbedx509.so.7
#   （openssl 变体 DEPENDS 声明的是 libopenssl，实际链的却是 mbedtls）
#
# 双变体入选的来源（本仓库配置实测）:
#   1) CONFIG_PACKAGE_luci-ssl=y —— luci feed 的 collections/luci-ssl
#      LUCI_DEPENDS 含 +libustream-mbedtls，选中即拉入 mbedtls 变体；
#   2) x86_64 等 TARGET_PER_DEVICE_ROOTFS 目标 —— lean
#      include/target.mk 的 DEFAULT_PACKAGES 含 libustream-openssl，
#      经 Kconfig "select DEFAULT_libustream-openssl" 使 openssl 变体
#      default y（tmp/.config-target.in 实证）。
#   两者叠加 → 双变体同时入选 → 共享构建目录互相污染。
#
# 为何不能放任多变体构建:
#   变体间声明的 CONFLICTS 仅写入 ipk 控制字段（include/package-ipkg.mk
#   的 addfield Conflicts），构建系统与镜像组装阶段均不强制；即使构建
#   成功，两个变体也会向 rootfs 装入同一个 SONAME（libustream-ssl.so）
#   的不同实现，后装者覆盖先装者，运行时静默错配。因此必须在配置层
#   保证唯一，并在编译前校验——把数小时后的 cryptic 失败转换为秒级
#   可操作错误。
#
# 处置（严格模式）:
#   恰好 1 个变体 → 放行；0 个或多个 → loud failure。
#   当前仓库配置固定保留 luci-ssl 的 mbedtls 变体，并在
#   config/x86_64.config 中显式关闭 openssl 变体。
# ============================================================
set -uo pipefail

SRC="${1:-lede}"
cd "$SRC" || exit 1
CONFIG=".config"
[ -f "$CONFIG" ] || { echo "错误: 找不到 $SRC/$CONFIG（应在本脚本之前完成 make defconfig）"; exit 1; }

selected=()
for v in openssl mbedtls wolfssl; do
  if grep -q "^CONFIG_PACKAGE_libustream-$v=[ym]" "$CONFIG"; then
    selected+=("$v")
  fi
done

echo "==> [ustream-ssl 变体校验] 已选变体: ${selected[*]:-（无）}"

if [ "${#selected[@]}" -eq 1 ]; then
  echo "    [OK] 唯一变体 libustream-${selected[0]}，无共享构建目录污染风险"
  exit 0
fi

if [ "${#selected[@]}" -eq 0 ]; then
  cat >&2 <<'EOF'
错误: 未选择任何 ustream-ssl 变体（libustream-openssl / mbedtls / wolfssl 均未选）。
  libustream-ssl.so 缺失会破坏依赖它的组件（uhttpd TLS、luci-ssl 等）。
  请检查 config/x86_64.config 是否误关闭了全部变体，或 luci-ssl 依赖是否变更。
EOF
  exit 1
fi

cat >&2 <<EOF
错误: 同时选择了多个 ustream-ssl 变体: ${selected[*]}。
  三个变体共享同一 PKG_BUILD_DIR（ustream-ssl Makefile 显式覆盖了
  include/package.mk 的按变体隔离默认值），后构建的变体会复用先构建
  变体的 CMake 缓存与产物，打包出链接错误 SSL 库的 .so，ipkg 依赖
  检查失败（run 11: libustream-openssl 缺失 libmbedcrypto.so.16 等）。
  常见叠加来源:
    1) CONFIG_PACKAGE_luci-ssl=y 拉入 libustream-mbedtls;
    2) x86_64 目标 DEFAULT_PACKAGES 含 libustream-openssl（target.mk）。
  修复: 在 config/x86_64.config 中显式关闭多余变体，例如
    # CONFIG_PACKAGE_libustream-openssl is not set
EOF
exit 1
