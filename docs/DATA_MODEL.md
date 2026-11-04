# 数据模型（DATA_MODEL）

> 与代码同步更新。最近核对：2026-10-31（schema v7）。

## 存储清单

| 介质 | 位置 | 内容 |
|---|---|---|
| SQLite（WAL） | `~/Library/Application Support/AgentAccountManager/main.sqlite` | 业务数据（7 张表） |
| Keychain | service `com.agentaccountmanager` | 完整手机号（key `phone:<accountId>`），可注入替代 |
| JSON 快照 | `~/Library/Application Support/AgentAccountManager/widget-snapshot.json` | Widget 只读快照（`.atomic` 写入） |
| UserDefaults | 标准 | 选中账号、收藏列表、面板可见性/置顶等偏好 |

## 表结构（schema v7）

### accounts（账号档案）
`id` PK · `platform`(trae|workbuddy) · `displayName` · `phoneMasked`（脱敏） · `phoneHash`（SHA-256，去重用） · `planType` · `note` · `lastLoginStatus`（unknown/verified/pendingConfirmation/userConfirmed…） · `lastCreditQueryAt` · `currentCredits` · `totalCredits` · `creditType` · `lastUsedAt` · `dataSource` · `dataStatus` · `traeUserDataDir` · `createdAt` · `updatedAt`

隐私约束：完整手机号不落库；`currentCredits` 查询失败保持 NULL，绝不写 0。

### credit_snapshots（积分快照）
`id` PK · `accountId` FK→accounts **ON DELETE CASCADE** · `credits` · `totalCredits` · `queryAt` · `source` · `status`（success/failed） · `errorMessage` · 索引 `(accountId, queryAt)`

### switch_logs（切换历史）
`id` PK · `accountId` FK→accounts CASCADE · `fromStatus` · `toStatus` · `result`（success/failed/…） · `errorMessage` · `createdAt` · 索引 `(accountId, createdAt)`

### trae_tasks（日志采集任务，v5）
`id` PK · `accountId` FK CASCADE · `sessionId` · `title` · `status` · `agentName` · `modelName` · `credits`（单任务消耗，来自日志，非官方余额） · `createdAt` · `updatedAt` · 索引 `(accountId, createdAt)`

### project_visits（项目访问，v6）
`id` PK · `accountId` FK CASCADE · `workspacePath` · `lastVisitedAt` · `visitCount` · `source` · **UNIQUE(accountId, workspacePath)** · 索引 `(accountId, lastVisitedAt)`

### projects（三工位项目，v7）
`id` PK · `displayName` · `repoPath` · `baselineBranch` · `orchestrationMode` · `buildCommand` · `testCommand` · `setupHint` · `worktreeRoot` · `projectMemory` · `note` · `createdAt` · `updatedAt`

### workstations（工位，v7）
`id` PK · `projectId` FK→projects CASCADE · `accountId` FK→accounts **ON DELETE SET NULL** · `displayName` · `roleTag` · `worktreePath` · `branchName` · `isEnabled` · `lastActivatedAt` · `createdAt` · `updatedAt`
约束：`UNIQUE(projectId, displayName)` · `UNIQUE(projectId, accountId)` · `UNIQUE(worktreePath)` · 索引 `(projectId, isEnabled)`、`(accountId)`

## 非 SQLite 数据

### WidgetSnapshot（JSON，schemaVersion=1）
`updatedAt` · `runningCount` · `accounts[]`（id/name/platform/isRunning/isFavorite/subtitle，副标题不含手机号） · `projects[]`（accountId/accountName/name=目录名/path/lastVisitedAt）。
读取规则：缺文件 / 损坏 / `schemaVersion > 1` 一律返回 nil，小组件展示空态；快照超过 24h 显示「数据已过期」提示（深链打开仍会校验）。

### Keychain
`KeychainStoring` 协议（生产实现 `KeychainService`，测试注入 `InMemoryKeychain`）。语义：写失败/权限拒绝返回 false，删除不存在的 key 返回 true。

## 数据生命周期

- 备份：`BackupRestore.backup(to:)`（WAL 下一致性快照，写后立即校验）。
- 恢复：校验 → 自动安全备份 → 替换 → 失败回滚 → 清理 `-wal/-shm` 边车。
- 清空：删除数据库文件 + 边车 + Keychain 全部条目；随后 `ServiceRegistry.install` 重建。
