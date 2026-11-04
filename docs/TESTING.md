# 测试说明（TESTING）

> 与代码同步更新。最近核对：2026-10-31。当前共 **177 项** XCTest，全部通过；`swift test` 即可运行（无需模拟器，含真实 Keychain 的用例在无钥匙串环境会自动 `XCTSkip`）。

## 运行

```bash
swift test                # 全量
swift test --filter SwitchServiceTests   # 单套件
```

约定：测试只用临时目录数据库与唯一 service 名（`com.agentaccountmanager.tests.<uuid>`），不触碰真实用户数据；写真实快照文件的路径被 Bundle ID 守卫挡住（测试进程 bundle 不是 `com.agentaccountmanager.app`）。

## 覆盖矩阵

| 模块 | 文件 | 要点 |
|---|---|---|
| 账号/积分/数据库 | AccountTests（42） | CRUD、脱敏与手机号哈希、手动录入、查询失败绝不置 0、历史、备份恢复（坏备份拒绝/安全备份）、清空（数据库+Keychain）、外键级联、平台语义 |
| 切换状态机 | SwitchServiceTests（13） | 目标缺失/平台变更/应用缺失/启动失败/启动但未核验/核验降级、**提交失败整体回滚**、切换日志缺失、互斥（并发拒绝+串行放行）、遗留路径容错 |
| 积分估算 | CreditBalanceCalculatorTests（9） | freshness/投影/过期边界矩阵 |
| 任务采集 | TraeTaskTests（20） | 解析器矩阵、扫描器增量、六元组统计（发现/解析/新增/更新/跳过/失败）、事务失败计失败 |
| 迁移/数据库 | MigrationTests（9） | 见 docs/DATABASE_MIGRATIONS.md；含迁移失败注入、WAL、**只读库故障注入** |
| Keychain | KeychainServiceTests（9） | 注入 `InMemoryKeychain`：保存/读取/更新/删除/不存在/权限拒绝/写入失败/明文边界；与 BackupRestore 清空集成。真实 Keychain 集成用例在 AccountTests（无环境自动跳过） |
| Worktree | WorktreeReconciliationTests（9）+ WorkbenchGitTests | 临时 Git 仓库：生命周期、重复路径拒绝、对账（异常退出/目录消失/未托管排除） |
| 快速切换快照 | QuickSwitchSnapshotBuilderTests（11） | 排序矩阵（收藏→运行→最近→平台→名称）、条数上限、runningCount 语义、副标题、schemaVersion/时间注入、**isStale 边界**、空输入 |
| Widget 快照 | WidgetSnapshotTests（8） | JSON 编解码往返、内容比较忽略时间戳、深链（合法/非法）、**缺文件/损坏/更高版本 → nil 空态** |
| 工作台 | WorkbenchTests.swift（19，含 WorkbenchDatabase/Git/Reconciliation/ServiceTests 与 StartupPreflightTests 7 项）+ WorkbenchAppStateTests（4） | 三工位 CRUD/校验/唯一约束、v7 迁移幂等、启动预检矩阵（基线失败/路径分支冲突/角色匹配/脏工作区）、prepare/execute/reuse |
| AppState 门面 | AppStateTests（7）+ CreditPresentationTests（7） | 公共 API 冒烟、门面转发、展示层语义 |
| 其他 | CSVExportTests（5）、ProjectVisitTests（5） | 导出、项目访问合并 |

## 故障注入清单（关键链路）

- 切换：预检成功启动失败 / 启动成功核验失败 / 核验成功但提交失败（整体回滚）/ 切换日志不可用。
- 数据库：事务中途失败回滚、迁移中途失败（版本与数据原样）、恢复文件损坏拒绝、数据库文件只读、WAL 边车清理。
- Widget：快照缺文件 / JSON 损坏 / schemaVersion 更高 / 过期 24h。
- Keychain：权限拒绝（读 nil、写删 false）、写入失败不破坏既有值。

## 日志测试约定

`AppLogger` 出口强制 `Masking.redactPhone`；测试断言日志相关行为时只验证「不含明文手机号」（`testRedactPhoneInLog`、Keychain 明文边界用例），不依赖具体日志文本。
