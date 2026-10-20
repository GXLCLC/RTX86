#!/bin/bash
# =====================================================================
# 02-third-party.sh —— 第三方插件稀疏拉取
# 策略：优先官方源码包，仅缺失时引入第三方
# 方式：--filter=blob:none + sparse-checkout 按需检出，--depth=1 裁剪历史
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 02-third-party.sh <lede源码目录>}"
# ---------- 第三方源定义 ----------
REPO_KENZOK8="https://github.com/kenzok8/openwrt-packages.git"  # kenzok8 插件源 master
REPO_SMALL="https://github.com/kenzok8/small-package.git"        # 依赖补充源 main
REPO_TURBOACC="https://github.com/mufeng05/turboacc.git"         # TurboACC 加速
REPO_OAF="https://github.com/destan19/OpenAppFilter.git"         # OAF 行为管理（含内核模块）
REPO_BANDIX="https://github.com/timsaya/luci-app-bandix.git"     # [新增] Bandix 前端
REPO_BANDIX_BACKEND="https://github.com/timsaya/openwrt-bandix.git" # [新增] Bandix 后端(eBPF采集)
# 需要的插件目录清单（可按需增删）
WANT_PKGS=(
    luci-app-smartdns luci-app-ddnsto luci-app-adguardhome luci-app-easytier
    luci-app-wechatpush luci-app-mwan3 luci-app-wol
    luci-app-upnp luci-app-ttyd luci-app-autoreboot
    # [已删除] luci-app-nlbwmon —— 带宽监控已由 Bandix 替代
)
# ---------- 前置校验函数：仓库连通性 + 分支存在性 ----------
precheck() {
    local repo="$1" branch="$2"
    echo ">> [前置校验] $repo (分支: $branch)"
    if ! git ls-remote --heads "$repo" "$branch" | grep -q "$branch"; then
        echo "ERROR: 仓库不可达或分支不存在 -> $repo [$branch]"
        echo "修复建议：1) 检查网络连通性；2) 确认分支名；3) 上游迁移/改名时同步更新本脚本"
        exit 1
    fi
}
# ---------- 稀疏拉取函数：部分克隆 + 稀疏检出 + 目录完整性校验 ----------
# 改动：把内部 exit 改为 return 1，交给外层 fallback 判断，其他内容一字不改
sparse_pull() {
    local repo="$1" branch="$2" dest="$3"; shift 3
    local dirs=("$@")
    echo ">> [稀疏拉取] $repo -> $dest（仅检出: ${dirs[*]}）"
    git clone --filter=blob:none --depth=1 --sparse -b "$branch" "$repo" "$dest" 2>/dev/null
    ( cd "$dest" && git sparse-checkout set --no-cone "${dirs[@]}" )
    # 目录完整性校验：目录不存在 return 1，交给外层处理，不再直接exit
    for d in "${dirs[@]}"; do
        if [ ! -e "$dest/$d" ]; then
            echo "NOTICE: 目录不存在或已更名 -> $repo/$d"
            return 1
        fi
    done
    return 0
}
# 新增：临时拉取插件并复制追加，不清空目标目录
pull_missing_append() {
    local repo="$1" branch="$2" dest="$3" pkg="$4"
    local tmp=".tmp_clone"
    rm -rf "$tmp"
    git clone --filter=blob:none --depth=1 --sparse -b "$branch" "$repo" "$tmp" 2>/dev/null
    (cd "$tmp" && git sparse-checkout set --no-cone "$pkg")
    if [ -d "$tmp/$pkg" ]; then
        cp -r "$tmp/$pkg" "$dest/"
        echo ">> ✅ 备选源补全：$pkg"
    else
        rm -rf "$tmp"
        echo "ERROR: $pkg 在两个仓库都找不到！"
        exit 1
    fi
    rm -rf "$tmp"
}
# ---------- 1. 全部第三方源前置校验 ----------
precheck "$REPO_KENZOK8"  master
precheck "$REPO_SMALL"    main
precheck "$REPO_TURBOACC" main
precheck "$REPO_OAF"      master
precheck "$REPO_BANDIX"   main
precheck "$REPO_BANDIX_BACKEND" main
# ---------- 2. 优先官方：官方已有则跳过，缺失才标记第三方拉取 ----------
MISSING=()
for pkg in "${WANT_PKGS[@]}"; do
    if find "${LEDE_DIR}/package" -maxdepth 3 -type d -name "$pkg" | grep -q .; then
        echo ">> [官方源] $pkg 已存在，优先使用官方源码包"
    else
        echo ">> [官方源] $pkg 缺失，列入第三方拉取清单"
        MISSING+=("$pkg")
    fi
done
# ===================== 只修改这一段，其余保持原样 =====================
if [ ${#MISSING[@]} -gt 0 ]; then
    TARGET="${LEDE_DIR}/package/kenzok8-packages"
    mkdir -p "$TARGET"
    # Step1：首选源批量拉取全部缺失插件
    echo ">> [Primary首选源] 批量拉取全部缺失插件"
    sparse_pull "$REPO_KENZOK8" master "$TARGET" "${MISSING[@]}" || true
    # Step2：自动筛选出主仓没有拉到的插件
    MISSING_AFTER=()
    for pkg in "${MISSING[@]}"; do
        if [ ! -d "${TARGET}/$pkg" ]; then
            MISSING_AFTER+=("$pkg")
        fi
    done
    # Step3：只对缺失插件，去备选仓追加拉取，不覆盖已有文件
    if [ ${#MISSING_AFTER[@]} -gt 0 ]; then
        echo ">> [Fallback备选源] 补拉缺失插件：${MISSING_AFTER[*]}"
        for pkg in "${MISSING_AFTER[@]}"; do
            pull_missing_append "$REPO_SMALL" main "$TARGET" "$pkg"
        done
    fi
fi
# ======================================================================
# ---------- 4. small-package 依赖补充（浅克隆整仓 + 历史裁剪）----------
echo ">> [依赖补充] 拉取 small-package（main 分支）"
git clone --filter=blob:none --depth=1 -b main "$REPO_SMALL" "${LEDE_DIR}/package/small-package"
# ---------- 5. TurboACC（仅检出面板目录；SFE 相关由冲突脚本移除）----------
sparse_pull "$REPO_TURBOACC" main "${LEDE_DIR}/package/turboacc" luci-app-turboacc
# ---------- 6. OAF 行为管理（面板 + 内核模块源码，随官方内核本地编译）----------
sparse_pull "$REPO_OAF" master "${LEDE_DIR}/package/openappfilter" luci-app-oaf open-app-filter
# ---------- 7. [新增] Bandix 流量监控（前端 + 后端，独立仓库，不走 kenzok8 兜底）----------
sparse_pull "$REPO_BANDIX" main "${LEDE_DIR}/package/bandix" luci-app-bandix
sparse_pull "$REPO_BANDIX_BACKEND" main "${LEDE_DIR}/package/bandix-backend" openwrt-bandix
# ---------- 8. 依赖可用性最终校验 ----------
for pkg in "${WANT_PKGS[@]}" luci-app-turboacc luci-app-oaf luci-app-bandix openwrt-bandix; do
    if ! find "${LEDE_DIR}/package" -maxdepth 3 -type d -name "$pkg" | grep -q .; then
        echo "ERROR: 插件 $pkg 拉取后仍未找到，依赖不可用"
        echo "修复建议：检查该插件在上游仓库中的实际目录名"
        exit 1
    fi
done
echo ">> 第三方插件全部就绪"
