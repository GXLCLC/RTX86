仓库结构
lede-cloud-build/
├── .github/
│   └── workflows/
│       └── build-x86-64.yml        # 主工作流（仅手动触发，全步骤中文注释）
├── config/
│   └── X86_64.config               # 编译配置（用户可增删插件）
├── scripts/
│   ├── 01-custom-settings.sh       # 自定义脚本：密码 / 主机名 / 后台IP / 时区
│   ├── 02-third-party.sh           # 第三方插件：前置校验 + 稀疏拉取
│   ├── 03-conflict-fix.sh          # 依赖冲突处理：保留官方内核，移除冲突模块
│   ├── 04-verify-image.sh          # 产物校验：文件 / 格式 / 根分区2G扩容
│   └── 05-release-body.sh          # 生成Release说明：版本 + 纯净插件清单
└── README.md
