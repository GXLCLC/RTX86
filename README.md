# RTX86 - lean LEDE x86_64 全自动云编译仓库

基于 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) master 源码，使用 **Ubuntu 24.04 LTS + GitHub Actions** 全自动云编译 **X86_64 Generic** 固件，全程无人值守，编译成功自动发布 Release。

## 快速开始

1. 进入仓库 **Actions → RTX86-LEDE-x86_64 → Run workflow** 手动触发；
2. 等待编译完成（首次约 2~4 小时，命中 DL 缓存后显著加速）；
3. 在 **Releases** 页面下载 `YYYYMMDD-HHMMSS-lede-x86_64-squashfs.img.gz`。

## 默认固件参数

| 项目 | 默认值 |
| --- | --- |
| 后台地址 | `http://192.168.2.1` |
| 登录账号 | `root` |
| 登录密码 | `12345678` |
| 默认主题 | Argon |
| 时区 | Asia/Shanghai |
| rootfs 分区 | 2048 MiB（overlay 2 GiB 可写分区） |

## 仓库目录结构

```
RTX86/
├── .github/
│   └── workflows/
│       └── build.yml            # 编译工作流（每行中文注释）
├── config/
│   └── x86_64.config            # 固件插件与内核配置（可自由增删软件包）
├── scripts/
│   ├── custom_settings.sh       # 后台密码/主机名/网络参数/时区/主题
│   ├── fetch_thirdparty.sh      # 第三方源浅克隆 + 前置校验
│   ├── patch_turboacc.sh        # 适配 add_turboacc.sh 的 lean 全架构内核版本矩阵
│   ├── cleanup_conflicts.sh     # 冲突清理（重复插件/预编译 kmod）
│   ├── verify_image.sh          # 镜像校验（分区/格式/squashfs 完整性）
│   ├── package_firmware.sh      # 时间戳打包 + 多余镜像清理
│   └── gen_release_notes.sh     # Release 说明生成
└── README.md
```

## 预装插件清单

| # | 插件 | 来源 |
| --- | --- | --- |
| 1 | luci-app-smartdns | 官方 feeds |
| 2 | luci-app-ddnsto | kenzok8/openwrt-packages |
| 3 | luci-app-adguardhome（含主程序） | 官方界面 + kenzok8 主程序 |
| 4 | luci-app-oaf + kmod-oaf | kenzok8/small-package |
| 5 | luci-app-turboacc（流量分载/全锥NAT/BBR） | 官方界面 + mufeng05 补丁 |
| 6 | luci-app-mwan3 | 官方 feeds |
| 7 | luci-theme-argon-config | 官方 feeds |
| 8 | luci-theme-argon | 官方 feeds |
| 9 | luci-app-nlbwmon | 官方 feeds |
| 10 | luci-app-easytier | kenzok8/small-package |
| 11 | luci-app-wol | 官方 feeds |
| 12 | luci-app-upnp | 官方 feeds |
| 13 | luci-app-ttyd | 官方 feeds |
| 14 | luci-app-autoreboot | 官方 feeds |
| 15 | luci-app-wechatpush | 官方 feeds |

所有带 i18n 的插件均已绑定 `zh-cn` 中文语言包；所有内核模块（kmod-oaf、kmod-nft-fullcone 等）均随源码内核现场编译，与编译内核版本严格一致。

## 工作流规则

- **触发**：仅 `workflow_dispatch` 手动触发（已关闭 push / pull_request 自动触发）；
- **环境**：固定 `ubuntu-24.04`，Job 超时 360 分钟；
- **并发锁**：同分支自动取消正在运行的旧任务；
- **源码**：固定拉取 `coolsnowwolf/lede` master，浅克隆；
- **拉取优先级**：官方 feeds → 第三方源（kenzok8 两个源 + turboacc）→ 独立插件，全部 `--depth=1 --filter=tree:0` 浅克隆，拉取前校验连通性 / 分支 / 目录 / Makefile；
- **网络容错**：feeds update 与第三方源克隆均带 3 次重试 + 索引非空校验，瞬时网络抖动不再中断编译（克隆失败的 feed 会静默产出空索引，直到 make 阶段才报错，故必须前置拦截）；
- **冲突处理**：自动删除第三方源中与官方重复的插件目录与全部预编译 `.ipk`；
- **分区**：rootfs 分区强制 2048 MiB，编译后自动校验分区容量 / 文件格式 / squashfs 完整性，不达标直接终止；
- **严格编译**：任一软件包编译报错立即终止整体任务，失败自动上传完整日志；
- **产物**：仅保留 `YYYYMMDD-HHMMSS-lede-x86_64-squashfs.img.gz`，其余镜像自动清理；
- **发布**：img.gz 未生成则判定失败不创建 Release；成功后自动创建 Release 并上传（写入 commit / 内核版本 / 编译时间 / 插件清单）。

## 自定义配置

- 增删软件包：编辑 `config/x86_64.config`（无需改 yml）；
- 修改后台 IP / 密码 / 主机名 / 时区 / 主题：编辑 `scripts/custom_settings.sh`；
- 增删第三方源：编辑 `scripts/fetch_thirdparty.sh` 的 `THIRD_REPOS`。
