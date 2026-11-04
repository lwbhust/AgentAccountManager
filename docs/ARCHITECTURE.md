# 技术手册（ARCHITECTURE）

> 与代码同步维护。适用版本 0.1.0，schema v7，macOS 14+。

## 1. 技术选型

| 项 | 选择 | 原因 |
|---|---|---|
| 语言 / UI | Swift 5.10+、SwiftUI + AppKit | 纯原生、无第三方依赖，安装包小、启动快 |
| 工程 | Swift Package Manager | `swift build` / `swift test` 一条命令完成构建与回归 |
| 存储 | SQLite（系统 `libsqlite3`）+ WAL | 单文件、可备份、迁移可控；不引入 ORM |
| 凭据 | macOS Keychain | 完整手机号不落库；业务库只存脱敏值与 SHA-256 摘要 |
| 组件通信 | JSON 快照 + App Group 替代方案 | Widget 扩展只读快照，深链回主应用 |
| 分发 | `package.sh` 手工组装 `.app` + ad-hoc 签名 | 无需 Xcode 工程文件，源码直接可构建 |

## 2. Target 与分层

```
AgentAccountManager（可执行） ──▶ Core（library）
AgentAccountManagerWidget（可执行） ──▶ Core
CoreTests（测试） ──▶ Core + AgentAccountManager
```

```
┌─ AgentAccountManager.app ─────────────────────────────────────┐
│  SwiftUI Views · QuickSwitch NSPanel · Workbench 视图          │
│        ↓ 只依赖 AppState 门面                                   │
│  AppState（公共 API / 绑定 / objectWillChange 统一转发）        │
│        ↓ 组装                                                   │
│  Stores：Account · Credit · Task · Running · QuickSwitch       │
│        ↓ 通过 ServiceRegistry 持有（备份恢复后整体重建）         │
│  Core：Services · Persistence/Migrations · Models · Utils      │
└────────────────────────────────────────────────────────────────┘
┌─ AgentAccountManagerWidget.appex ─────────────────────────────┐
│  WidgetKit：只读 widget-snapshot.json，深链回主应用             │
└────────────────────────────────────────────────────────────────┘
```

设计约束：

- `Core` 不依赖 SwiftUI / WidgetKit；平台启动能力（`NSWorkspace`）由 App 装配层注入，便于测试替身。
- 视图层不直接调用 Service，统一经 `AppState`，保证状态刷新与业务入口唯一。
- `ServiceRegistry` 在恢复备份 / 清空数据后整体替换服务实例，避免 Store 捕获旧连接。

## 3. 模块职责

| 目录 / 文件 | 职责 |
|---|---|
| `Sources/AgentAccountManager/AppState.swift` | 服务装配、账号列表与筛选、余额缓存、运行状态、任务采集、备份恢复入口 |
| `Sources/AgentAccountManager/Stores/` | 领域状态拆分：账号、积分、任务、运行态、快速切换 |
| `Sources/AgentAccountManager/Views/` | 主窗口、账号列表/详情、表单、切换向导、设置、导出 |
| `Sources/AgentAccountManager/QuickSwitch/` | 无边框悬浮面板：置顶、位置与可见性记忆、账号/项目快捷打开 |
| `Sources/AgentAccountManager/Workbench/` | 三工位工作台窗口路由与状态 |
| `Sources/AgentAccountManager/DesignSystem/` | 颜色、字体、间距、材质与背景 |
| `Sources/Core/Models/` | Account、Platform、Credit、TraeTask、Project、Workstation 等模型 |
| `Sources/Core/Services/` | 账号、积分、切换、TRAE、WorkBuddy、任务采集、备份、导出、worktree |
| `Sources/Core/Persistence/Migrations/` | v0→v7 独立迁移文件，按 `PRAGMA user_version` 顺序执行 |
| `Sources/Core/Widget/` | 快照模型、排序与组装纯函数（主应用与 Widget 共用） |
| `Sources/AgentAccountManagerWidget/` | WidgetKit 视图与时间线，只读快照 |
| `Tests/CoreTests/` | 177 项 XCTest：服务、迁移、故障注入、快照、工作台 |

## 4. 关键链路

### 4.1 账号切换（SwitchService）

状态机：`Precheck → Launch → Verify → Commit`，全程 `OSAllocatedUnfairLock` 互斥。

- Precheck：平台、应用安装、目标账号与上次项目校验。
- Launch：TRAE 以 `--user-data-dir <账号目录>` 启动独立实例；WorkBuddy 仅打开唯一客户端。
- Verify：TRAE 尝试官方 CLI 核验身份；不可用时降级为「等待核对」，绝不伪造成功。
- Commit：登录状态、`lastUsedAt`、项目访问、切换日志在同一事务内提交；任一步失败整体回滚并写入失败日志。

可注入边界：应用启动器、进程查询、LaunchServices 解析，便于单元测试覆盖失败分支。

### 4.2 TRAE 任务与积分采集

`TraeTaskScanner`（actor）只读取本应用创建的账号目录下的 `logs/**/window*/renderer.log`：

- 增量读取：按文件偏移量消费，只推进到最后一个完整换行，半行留到下次。
- 轮转与截断：文件变小则从头读取；首次读取只取尾部 16 MB。
- 补采范围：最近 2 轮日志、最多 7 天、每轮最多 8 个窗口文件。
- 偏移持久化：写入 `UserDefaults`，应用重启后继续增量读取。
- 解析：`TraeTaskParser` 识别元数据、单轮积分、结束状态三类日志行；`TraeTaskService` 以 `messageId` 合并去重。
- 诊断采用六元组：发现 / 解析 / 新增 / 更新 / 跳过 / 失败；格式变化单独计为「疑似格式异常」。

积分余额由 `CreditBalanceCalculator` 纯函数计算：最近一次手动录入余额减去基准之后已采集的任务消耗；未采集消耗不按 0 计入，查询失败绝不写 0。

### 4.3 快速切换与 Widget

- NSPanel 与 Widget 使用同一数据源和同一排序规则：收藏 → 运行中的 TRAE → 最近使用 → 平台/名称。
- 排序与快照组装收敛在 `Core/Widget/QuickSwitchSnapshotBuilder`（纯函数，可测）。
- 主应用原子写入 `widget-snapshot.json`（内容去重、失败回滚）；Widget 只读，缺文件/损坏/更高 schemaVersion 一律空态。
- 深链 `agentaccountmanager://account/<id>` 与 `.../project/<id>?path=` 回主应用，打开前重新校验账号与目录存在。
- 快照超过 24 小时，Widget 标注「数据已过期」。

### 4.4 三工位工作台

`WorkbenchService` 聚合项目、工位与 `GitWorktreeService`：

- 每个项目可绑定多个工位，每个工位对应独立 worktree 与分支。
- 启动前 `StartupPreflight` 校验基线分支、路径冲突、角色匹配、工作区是否干净。
- `WorktreeReconciliation` 对账识别「注册存在但目录消失」等异常退出残留；所有 Git 操作只在临时测试仓库中验证，不触碰用户真实仓库。

## 5. 持久化与迁移

| 介质 | 位置 | 内容 |
|---|---|---|
| SQLite | `~/Library/Application Support/AgentAccountManager/main.sqlite` | 7 张业务表（schema v7） |
| Keychain | service `com.agentaccountmanager` | 完整手机号 `phone:<accountId>` |
| JSON | 同目录 `widget-snapshot.json` | Widget 只读快照 |
| UserDefaults | 标准域 | 选中账号、收藏、面板状态、扫描偏移 |

迁移规则：

- 每个版本一个独立 `Migration`，按 `user_version` 顺序执行，失败时版本与数据保持原样。
- 连接统一启用 `foreign_keys=ON`、`WAL`、`busy_timeout`。
- 表结构详见 [DATA_MODEL.md](DATA_MODEL.md)，迁移历史见 [DATABASE_MIGRATIONS.md](DATABASE_MIGRATIONS.md)。

## 6. 可靠性约定

- 所有服务错误为具名 `LocalizedError`，提供可操作的中文描述，不静默降级。
- 查询失败不写 0；切换失败不写成功状态；采集失败如实计入 failed。
- 并发入口去重：切换互斥、`isCollecting`、`isRefreshing`。
- 备份恢复：`integrity_check` 校验 → 自动安全备份 → 替换 → 失败回滚 → 清理 WAL/SHM 边车。

## 7. 日志与隐私

- `AppLogger` 固定 subsystem `com.agentaccountmanager`，按模块区分 category。
- 日志出口强制手机号脱敏，禁止写入密码、Token、Cookie、原始日志全文。
- SQLite 只存脱敏手机号与 SHA-256 摘要；完整手机号只进 Keychain。
- 不复制、不修改 TRAE / WorkBuddy 的认证文件与配置；只使用官方 `--user-data-dir` 能力。

## 8. 构建与打包

```bash
swift build                 # Debug
swift test                  # 177 项
./package.sh                # dist/AgentAccountManager.app
./package.sh --install      # 安装到 /Applications（不可写回退 ~/Applications）
```

`package.sh` 流程：Release 构建 → 组装 `.app`（Info.plist、图标、背景、Widget appex）→ ad-hoc 签名（先扩展后外层）→ 可选安装（LaunchServices 注册、`pluginkit` 注册、注销并删除 dist 副本、刷新 Dock）。

Bundle ID：主应用 `com.agentaccountmanager.app`，Widget `com.agentaccountmanager.app.widget`；URL scheme `agentaccountmanager`；最低系统 macOS 14.0。
