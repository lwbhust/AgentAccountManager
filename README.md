<div align="center">

![Agent 账号管理器图标](https://cdn.jsdelivr.net/gh/lwbhust/AgentAccountManager@main/assets/icon-200.png)

# Agent 账号管理器

**为 TRAE 多账号而生的 macOS 本地账号工作台**

独立实例 · 快速切换 · 最近项目 · 任务与积分台账 · 三工位 Worktree

[![Platform](https://img.shields.io/badge/macOS-14%2B-black)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-orange)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

[快速开始](#-一键安装) · [TRAE 优化](#-为-trae-多账号做的优化) · [使用方式](#-使用方式) · [技术手册](docs/ARCHITECTURE.md)

</div>

---

## 这是什么

同一台 Mac 上管理多个 TRAE 账号，通常要在不同账号之间反复退出登录、切换配置，项目历史、任务记录和积分消耗也随之丢失。**Agent 账号管理器**把这件事收敛成一个本地桌面应用：

- 每个 TRAE 账号绑定一个**内核参数隔离的独立配置目录**（`--user-data-dir`），账号数据互不污染；
- 一键打开、激活或恢复上次项目，不必再记路径；
- 从本地运行日志增量采集任务与单任务积分，形成可追溯的消耗台账；
- 一个常驻的快速切换面板 + 通知中心 Widget，随时切号或打开项目；
- 所有数据只保存在本机，不复制、不修改官方认证文件。

同时兼容 WorkBuddy 的单实例人工切换：它没有被官方支持的账号隔离能力，应用会明确区分「客户端已打开」与「该账号已登录」，不伪造状态。

> 纯 Swift + SwiftUI/AppKit，无第三方依赖；SQLite + Keychain + 原子 JSON 快照。

## ✨ 为 TRAE 多账号做的优化

### 1. 内核级隔离：一个账号一份独立实例

TRAE 基于 VS Code / Electron 内核，可直接使用内核自带的 `--user-data-dir` 参数。应用为每个账号创建独立目录：

```
~/Library/Application Support/AgentAccountManager/TraeUserData/<账号 UUID>
```

启动时以该目录拉起实例，登录态、插件、工作区缓存天然隔离。**不复制、不注入、不篡改任何认证文件**，只使用内核自带的启动参数。

### 2. 进程级运行状态识别

通过 `ps` 解析每个 TRAE 进程的 `--user-data-dir`，精确判断「哪个账号的实例正在运行」，而不是只看「TRAE 是否在运行」。只激活实例、不指定项目时，如果已有窗口会直接激活，不再拉起 CLI；需要聚焦到具体项目时仍走官方 CLI 转发（会有一个短命转发进程），以保证窗口定位准确。

### 3. 一键回到上次项目

记录每个账号最近打开的工作区（精确记录 + `workspace.json` 时间推断兜底），主按钮直接显示「启动 TRAE · 项目名」。侧边栏与快速切换面板提供跨账号的最近项目列表（近 7 天最多 15 条）。

### 4. 任务与积分台账，不猜、不补零

TRAE 把任务运行日志写在实例的 `logs/**/window*/renderer.log`。采集器只读这些日志：

- **增量读取**：按文件偏移消费，只推进到最后一个完整换行，半行不会丢；
- **轮转/截断/重启恢复**：文件变小自动重读，偏移持久化到 `UserDefaults`；
- **补采窗口**：最近 2 轮、最多 7 天、每轮最多 8 个窗口文件；
- **六元组诊断**：发现 / 解析 / 新增 / 更新 / 跳过 / 失败，格式变化单独提示；
- **积分语义**：手动录入实际余额后，预计余额 = 录入值 − 基准之后已采集消耗；未采集消耗不按 0 计入，查询失败绝不写 0。

### 5. 快速切换面板 + Widget

- `⌥⌘K` 呼出无边框悬浮面板，置顶于所有桌面空间；账号按「收藏 → 运行中的 TRAE 实例 → 最近使用」排序。
- 面板与通知中心 Widget 共用同一排序与快照实现，行为一致。
- Widget 通过深链 `agentaccountmanager://account/<id>` / `.../project/<id>?path=` 回到主应用，打开前重新校验账号与目录；快照超过 24 小时标注「数据已过期」。

### 6. 切换是状态机，不是「点一下就算成功」

`Preflight → Launching → Verifying → Committing` 四阶段，服务级互斥；状态写入在单事务内提交，失败回滚，启动或核验失败不写成功状态。启动成功与登录成功严格区分，TRAE 官方 CLI 不可用时降级为「等待核对」，绝不伪造「已验证」。

### 7. 三工位 Worktree 工作台

把「一个项目 × 多个账号 × 多个分支」落到 Git worktree：每个工位独立目录与分支，启动前预检基线、路径冲突、角色匹配、工作区干净度；异常退出后可对账识别目录丢失、登记丢失与分支漂移，清理仍走确认流程。

## 🚀 一键安装

### 方式 A：克隆后安装（推荐）

```bash
git clone https://github.com/lwbhust/AgentAccountManager.git
cd AgentAccountManager
./install.sh
```

### 方式 B：一行命令

```bash
curl -fsSL https://raw.githubusercontent.com/lwbhust/AgentAccountManager/main/install.sh | bash
```

脚本会自动检查 macOS 14+ 与 Swift 工具链，执行 Release 构建、组装 `.app`、ad-hoc 签名，并安装到 `/Applications`（不可写时回退 `~/Applications`），最后刷新 LaunchServices 与 Dock。

安装完成后直接打开「Agent 账号管理器」。首次启动若被 Gatekeeper 拦截，右键应用选择「打开」即可。

> 环境要求：macOS 14+、完整 Xcode（或可用的 Swift 5.10+ 工具链）。不需要 CocoaPods、Node 或任何第三方依赖。

### 构建而不安装

```bash
./install.sh --no-install   # 产物在 dist/AgentAccountManager.app
./package.sh                # 同上，直接调用打包脚本
```

## 📖 使用方式

1. **新增账号**：`⌥⌘N`，选择 TRAE / WorkBuddy，填写名称（手机号可留空）。
2. **启动并核对登录**：TRAE 选择「打开此账号」或「启动并核对登录…」，在独立窗口中登录后点「我已核对并登录」。
3. **录入积分**：在官方界面看到剩余积分后，详情页「录入积分」填写数值与观测时间。
4. **查看消耗**：TRAE 账号在本应用启动的实例里执行任务后，「任务消耗（日志）」自动出现，每 5 秒增量刷新。
5. **日常切换**：`⌥⌘K` 呼出快速切换面板，点击账号即恢复上次项目并打开/激活实例。

常用快捷键：

| 快捷键 | 行为 |
|---|---|
| `⌘F` | 聚焦搜索 |
| `⌘↩` | 打开所选账号（优先恢复上次项目） |
| `⌘⇧↩` | 为所选账号启动空白窗口 |
| `⌥⌘K` | 显示 / 隐藏快速切换面板 |
| `⌘D` | 收藏 / 取消收藏 |
| `⌘R` | 立即采集 TRAE 任务日志 |
| `⌥⌘N` | 新增账号 |
| `⌘,` | 设置 |

完整操作说明见 [使用手册](docs/USAGE.md)。

## 🧱 代码框架

```text
AgentAccountManager/
├── Package.swift                 # SwiftPM：主应用 / Widget / Core 三个 target
├── package.sh                    # Release 构建 + 组装 .app + 可选安装
├── install.sh                    # 一键环境检查、构建、安装
├── Sources/
│   ├── AgentAccountManager/      # App 层
│   │   ├── AppState.swift        # 门面：服务装配、状态转发
│   │   ├── Stores/               # 账号 / 积分 / 任务 / 运行态 / 快速切换
│   │   ├── Views/                # 主窗口、详情、表单、设置、工作台
│   │   ├── QuickSwitch/          # NSPanel 悬浮面板
│   │   ├── Workbench/            # 三工位窗口路由
│   │   └── DesignSystem/         # 颜色、字体、间距、背景
│   ├── Core/                     # 无 UI 依赖的业务内核
│   │   ├── Models/               # 账号、平台、积分、任务、项目、工位
│   │   ├── Services/             # 切换、TRAE、采集、备份、Git worktree…
│   │   ├── Persistence/          # SQLite 封装与 v0→v7 迁移
│   │   ├── Widget/               # 快照模型与排序纯函数
│   │   └── Utils/                # 日志脱敏、手机号掩码
│   └── AgentAccountManagerWidget/# WidgetKit 扩展
├── Tests/CoreTests/              # 177 项单元测试
├── assets/                       # 图标、背景、Widget entitlements
└── docs/                         # 架构、数据模型、迁移、测试、设计系统、使用手册
```

一次界面操作的数据流：

```
View → AppState → Store/Service → SQLite / Keychain / 系统进程
```

详细分层、关键链路与可靠性约定见 [技术手册](docs/ARCHITECTURE.md)。

## 🔒 数据与隐私

| 数据 | 位置 |
|---|---|
| 账号、积分、任务、切换历史 | `~/Library/Application Support/AgentAccountManager/main.sqlite` |
| 完整手机号 | macOS Keychain（service `com.agentaccountmanager`） |
| Widget 快照 | 同目录 `widget-snapshot.json`（只读、原子写） |
| 偏好与采集偏移 | `UserDefaults` |

- 数据库只保存**脱敏手机号**与 SHA-256 摘要，完整号码只进 Keychain；
- 日志出口强制脱敏，不记录密码、Token、Cookie；
- 不复制、不修改 TRAE / WorkBuddy 的认证与配置；
- 支持本地备份、恢复（自动安全备份 + 失败回滚）、CSV 导出与清空数据；
- 卸载应用不会删除数据，清空请在设置中显式操作。

## 🛠 开发与测试

```bash
swift build                 # Debug 构建
swift test                  # 177 项单元测试
swift build -c release      # Release 构建
./package.sh --install      # 打包并安装
```

测试覆盖：账号与积分 CRUD、切换状态机与事务回滚、迁移故障注入、Keychain 注入矩阵、任务日志解析与增量扫描、Widget 快照异常路径、QuickSwitch 排序、Git worktree 生命周期、启动预检。

更多： [测试说明](docs/TESTING.md) · [数据模型](docs/DATA_MODEL.md) · [迁移记录](docs/DATABASE_MIGRATIONS.md) · [设计系统](docs/DESIGN_SYSTEM.md)

## ⚠️ 已知边界

- **WorkBuddy 不支持自动切号**：官方只允许单实例单账号，应用只负责打开客户端与记录核对状态。
- **TRAE 首次登录仍需人工**：隔离目录首次使用要在官方窗口登录一次；应用不会代替你登录。
- **任务日志格式非公开**：采集依赖 TRAE 本地日志；格式变化时应用会提示「疑似格式异常」，而不是静默丢数据。
- **ad-hoc 签名**：未做 Developer ID 公证，首次启动可能需要右键「打开」。
- **仅支持 macOS 14+**：依赖 SwiftUI 与 WidgetKit 的较新 API。

## 🤝 参与贡献

欢迎提交 Issue 或 PR。开始前请先跑通 `swift build && swift test`，新增行为请附带对应测试，并保持「不伪造数据、不修改官方配置、不泄露凭据」三条底线。

## 📄 License

[MIT](LICENSE) © 2026 Agent Account Manager
