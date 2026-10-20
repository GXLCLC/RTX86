#!/bin/bash
# =====================================================================
# 02-third-party.sh —— 多级源优先级：Lean Feeds > kenzok8 > small > 独立专项仓
# 策略：优先官方feed批量拉取，扫描成果，差分补漏；只对缺失项下沉到下级源
# 方式：--filter=blob:none + sparse-checkout 按需检出，--depth=1 裁剪历史
# 优先级顺序：coolsnowwolf feeds → kenzok8/openwrt-packages → small-package → 独立仓库
# Feed清单：packages + luci(openwrt-25.12) + routing，已移除无用telephony
# =====================================================================
set -e
LEDE_DIR="${1:?用法: 02-third-party.sh <lede源码目录>}"

# ========================【第一步：优先写入Lean官方feed源】========================
FEEDS_CONF="${LEDE_DIR}/feeds.conf.default"
cat > "$FEEDS_CONF" <<EOF
src-git packages https://github.com/coolsnowwolf/packages.git
src-git luci https://github.com/coolsnowwolf/luci.git;openwrt-25.12
src-git routing https://github.com/coolsnowwolf/routing.git
EOF
echo ">> ✅ 【L1】已写入Lean官方feed配置（packages master + luci openwrt-25.12 + routing master）"
# ========================================================================================

# ========================【第二步：执行feed更新+安装，拉取官方源软件包】========================
cd "${LEDE_DIR}"
echo ">> ✅ 【L1】开始 feeds update -a"
./scripts/feeds update -a
echo ">> ✅ 【L1】开始 feeds install -a"
./scripts/feeds install -a
cd - > /dev/null

# ---------- 第三方源定义 ----------
REPO_KENZOK8="https://github.com/kenzok8/openwrt-packages.git"  # L2 首选第三方包源 master
REPO_SMALL="https://github.com/kenzok8/small-package.git"        # L3 备选依赖源 main
REPO_TURBOACC="https://github.com/mufeng05/turboacc.git"         # L4 独立专项：TurboACC 加速
REPO_OAF="https://github.com/destan19/OpenAppFilter.git"         # L4 独立专项：OAF 行为管理
REPO_BANDIX="https://github.com/timsaya/luci-app-bandix.git"     # L4 独立专项：Bandix 前端
REPO_BANDIX_BACKEND="https://github.com/timsaya/openwrt-bandix.git" # L4 独立专项：Bandix 后端(eBPF)

# 需要的通用插件清单（L1/L2/L3 三级包源检索对象；独立专项仓不在此清单）
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

# ---------- 【L1 结果扫描】：feed安装完成后，筛查缺失插件 ----------
MISSING=()
echo -e "\n>> [L1扫描] 检查Lean Feed安装结果"
for pkg in "${WANT_PKGS[@]}"; do
    if find "${LEDE_DIR}/package" -maxdepth 3 -type d -name "$pkg" | grep -q .; then
        echo ">> [L1命中] $pkg 来自Lean官方Feed，无需第三方拉取"
    else
        echo ">> [L1缺失] $pkg 未在Feed找到，下沉至L2源"
        MISSING+=("$pkg")
    fi
done

# ---------- 【L2 批次拉取】kenzok8/openwrt-packages，批量拉取所有L1缺失项 ----------
if [ ${#MISSING[@]} -gt 0 ]; then
    TARGET="${LEDE_DIR}/package/kenzok8-packages"
    mkdir -p "$TARGET"
    echo -e "\n>> [L2] 批量拉取缺失插件：${MISSING[*]}"
    sparse_pull "$REPO_KENZOK8" master "$TARGET" "${MISSING[@]}" || true

    # 【差分扫描】L2拉完再筛，剩下的下沉L3
    MISSING_AFTER_L2=()
    for pkg in "${MISSING[@]}"; do
        if [ ! -d "${TARGET}/$pkg" ]; then
            echo ">> [L2缺失] $pkg，下沉至L3 small-package"
            MISSING_AFTER_L2+=("$pkg")
        fi
    done

    # ---------- 【L3 逐个补漏】small-package，只补L2失败项 ----------
    if [ ${#MISSING_AFTER_L2[@]} -gt 0 ]; then
        echo -e "\n>> [L3] 补拉L2失败插件：${MISSING_AFTER_L2[*]}"
        for pkg in "${MISSING_AFTER_L2[@]}"; do
            pull_missing_append "$REPO_SMALL" main "$TARGET" "$pkg"
        done
    fi
fi

# ---------- 【L4 独立专项仓库固定拉取，不受上面清单控制】----------
echo -e "\n>> [L4] 拉取独立专项仓库 TurboACC"
sparse_pull "$REPO_TURBOACC" main "${LEDE_DIR}/package/turboacc" luci-app-turboacc

echo ">> [L4] 拉取独立专项仓库 OAF"
sparse_pull "$REPO_OAF" master "${LEDE_DIR}/package/openappfilter" luci-app-oaf open-app-filter

echo ">> [L4] 拉取独立专项仓库 Bandix"
sparse_pull "$REPO_BANDIX" main "${LEDE_DIR}/package/bandix" luci-app-bandix
sparse_pull "$REPO_BANDIX_BACKEND" main "${LEDE_DIR}/package/bandix-backend" openwrt-bandix

# ---------- 【最终全局校验】----------
CHECK_LIST=("${WANT_PKGS[@]}" luci-app-turboacc luci-app-oaf luci-app-bandix openwrt-bandix)
echo -e "\n>> [最终校验] 检查全部插件是否就绪"
for pkg in "${CHECK_LIST[@]}"; do
    if ! find "${LEDE_DIR}/package" -maxdepth 3 -type d -name "$pkg" | grep -q .; then
        echo "ERROR: 插件 $pkg 经过L1/L2/L3/L4多级拉取后仍未找到，依赖不可用"
        echo "修复建议：检查该插件在上游仓库中的实际目录名"
        exit 1
    fi
done

echo -e "\n>> ✅ 多级源拉取流程全部完成！"
