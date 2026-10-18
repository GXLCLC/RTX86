#!/bin/bash
# ============================================================
# inject_turboacc_patches.sh - 强制注入并逐文件校验 turboacc 补丁
# 用法: bash scripts/inject_turboacc_patches.sh <源码目录>
#
# 背景:
#   add_turboacc.sh 用 cp -rf 把 turboacc 的 5 组补丁覆盖注入 lean 源码树，
#   但该脚本无 set -e，拷贝失败会静默继续。run 6 实测: clone 成功、全程
#   无任何报错，但 lean 自带的破损补丁未被覆盖——编译 2 小时后才在
#   iptables 打补丁阶段爆雷：
#       can't find file to patch at input line 3
#       |--- a/extensions/libxt_NAT.c      <- iptables 1.8.7 已删除该文件
#       Patch failed!  Please fix ./patches/900-bcm-fullconenat.patch!
#
#   补充事实: lean master 已上游收录 turboacc 除 iptables 900 外的全部
#   补丁（五组同名补丁内容一致），iptables/900 是唯一实质性覆盖点——
#   lean 版改 extensions/libxt_NAT.c（必败），turboacc 版改
#   extensions/libipt_MASQUERADE.c（与 1.8.7 兼容）。
#
# 处置:
#   编译前显式重拷 5 组补丁，逐文件 cmp 校验，任何缺失/不一致立即
#   报错退出——把"2 小时后的编译地狱"变成"秒级的 loud failure"。
# ============================================================
set -euo pipefail

SRC="${1:-lede}"
cd "$SRC"

TA="package/turboacc"

# 目标包目录（相对 package/）-> turboacc 补丁源目录名，与 add_turboacc.sh 注入目标一致
TARGETS=(
  "network/utils/iptables:iptables"
  "network/utils/nftables:nftables"
  "libs/libnftnl:libnftnl"
  "network/config/firewall:firewall"
  "network/config/firewall4:firewall4"
)

if [ ! -d "$TA/lede/patches" ]; then
  echo "错误: 未找到 $TA/lede/patches（请先执行 fetch_thirdparty.sh 与 add_turboacc.sh）" >&2
  exit 1
fi

fail=0
total=0

for entry in "${TARGETS[@]}"; do
  tgt="${entry%%:*}"
  src_name="${entry##*:}"
  src="$TA/lede/patches/$src_name/patches"
  dst="package/$tgt/patches"

  echo "==> [注入] package/$tgt"

  if [ ! -d "$src" ]; then
    echo "    !! 错误: turboacc 补丁源不存在: $src（仓库结构可能已变化）"
    fail=1
    continue
  fi

  mkdir -p "$dst"
  n=0
  for pf in "$src"/*.patch; do
    [ -e "$pf" ] || continue # 空目录时 glob 不展开的兜底
    base=$(basename "$pf")
    cp -f "$pf" "$dst/$base"
    if cmp -s "$pf" "$dst/$base"; then
      n=$((n + 1))
    else
      echo "    !! 错误: 拷贝校验失败: $base（cp 后内容与源不一致）"
      fail=1
    fi
  done
  total=$((total + n))
  echo "    已注入并校验 $n 个补丁 -> $dst/"
done

if [ "$fail" -ne 0 ]; then
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "错误: turboacc 补丁注入校验失败（详见上方 !! 行）"
  echo "说明: add_turboacc.sh 的 cp -rf 在异常环境下可能未生效，本步骤"
  echo "      做确定性重注入；此处失败说明 turboacc 仓库结构已变或文件"
  echo "      系统异常，需人工检查后重新触发 Run workflow"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit 1
fi

echo "==> turboacc 补丁注入完成: 5 组目标共 $total 个补丁，逐文件 cmp 校验全部通过"
