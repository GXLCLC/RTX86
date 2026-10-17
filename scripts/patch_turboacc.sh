#!/bin/bash
# ============================================================
# patch_turboacc.sh - 适配 lean 源码全架构内核版本矩阵
# 用法: bash scripts/patch_turboacc.sh <源码目录>
# 背景: 上游 add_turboacc.sh 假设源码 include/ 下只有一个内核版本，
#       会遍历 ./include/kernel-* 检测到的所有版本逐一打补丁；
#       而 lean 源码含全架构版本矩阵（6.1/5.10/5.4/6.6/6.12/5.15/6.18），
#       遇到 turboacc 不支持的版本（如 x86 之外的 6.1/5.x）直接 exit 1，
#       导致 x86_64（实际使用受支持的 6.18）编译被误终止。
# 修复: 将"遇到不支持的版本即退出"改为"跳过该版本继续处理"，
#       并增加兜底校验——若一个受支持版本都没有则仍然报错退出，
#       防止未来 lean 调整 x86 内核版本时补丁未打上而静默失效。
# ============================================================
set -euo pipefail

SRC="${1:-lede}"
SCRIPT="$SRC/package/turboacc/add_turboacc.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "错误: 未找到 $SCRIPT（请先执行 fetch_thirdparty.sh 拉取第三方源）"
  exit 1
fi

# ---- 幂等检测: 已打过补丁则跳过 ----
if grep -q "RTX86-patched" "$SCRIPT"; then
  echo "==> add_turboacc.sh 已打过补丁，跳过"
  exit 0
fi

# ---- 用 python3 做精确多行替换（避免 sed 多行匹配的转义脆弱性） ----
python3 - "$SCRIPT" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    s = f.read()

# 1) 遇到不支持的内核版本: exit 1 -> continue（跳过非目标架构版本）
old_else = '''    else
        echo "Unsupported kernel version: $kernel_version"
        exit 1
    fi
'''
new_else = '''    else
        echo "跳过: 内核 $kernel_version 不在 turboacc 支持列表(6.6/6.12/6.18)，"
        echo "      lean 源码 include/ 含全架构版本矩阵，非当前 target 使用的版本无需处理"
        continue
    fi
'''
if old_else not in s:
    print("错误: 未匹配到 Unsupported 分支，add_turboacc.sh 结构可能已变化", file=sys.stderr)
    sys.exit(1)
s = s.replace(old_else, new_else, 1)

# 2) 循环结束后兜底: 至少要有一个受支持版本，否则补丁未打上将静默失效
anchor = '''done

cp -rf "$TMPDIR/turboacc/lede/luci-app-turboacc"'''
guard = '''done

# ---- RTX86-patched: 兜底校验，至少需要一个受支持的内核版本 ----
supported=0
for kv in $kernel_versions; do
  case "$kv" in 6.6|6.12|6.18) supported=1 ;; esac
done
if [ "$supported" -eq 0 ]; then
  echo "错误: 当前源码未检测到 turboacc 支持的内核版本(6.6/6.12/6.18)，终止以防补丁缺失" >&2
  exit 1
fi

cp -rf "$TMPDIR/turboacc/lede/luci-app-turboacc"'''
if anchor not in s:
    print("错误: 未匹配到补丁锚点，add_turboacc.sh 结构可能已变化", file=sys.stderr)
    sys.exit(1)
s = s.replace(anchor, guard, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(s)
print("patch_turboacc: add_turboacc.sh 已适配 lean 全架构内核版本矩阵")
PYEOF

# ---- 修补后自检: 不应再有 Unsupported 硬退出 ----
if grep -q 'echo "Unsupported kernel version' "$SCRIPT" && ! grep -q "跳过: 内核" "$SCRIPT"; then
  echo "错误: 补丁自检失败" >&2
  exit 1
fi
echo "==> patch_turboacc.sh 完成"
