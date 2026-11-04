# 数据库迁移（DATABASE_MIGRATIONS）

> 与代码同步更新。最近核对：2026-10-31。当前 `supportedSchemaVersion = 7`。

## 机制

- 版本号存于 `PRAGMA user_version`；迁移链在 `Sources/Core/Persistence/Migrations/`，每个迁移实现 `SchemaMigration`（`fromVersion`/`toVersion`/`apply(tx:)`）。
- **所有迁移在单个事务内执行**；失败即整体回滚，`user_version` 与数据保持原样（有注入故障测试锁定该行为）。
- 打开数据库时从未知版本升到最新；**绝不重建数据库**，v2→v3 的表重建也走「建新表→拷贝→改名」保留数据。
- 新字段一律显式迁移新增，不依赖默认值隐式生效。
- 连接配置（每次打开）：`foreign_keys = ON`、`busy_timeout = 5000`、`journal_mode = WAL`（启用失败记日志并沿用默认，不阻断）。
- 版本高于当前支持（`user_version > 7`）的数据库保持原样不动，由用户决定（如恢复旧备份）。

## 迁移清单

| 版本 | 内容 |
|---|---|
| v0 → v1 | 初始建表：`accounts`、`credit_snapshots`（FK CASCADE）、`switch_logs`（FK CASCADE）及索引 |
| v1 → v2 | 清理孤儿行：删除 `accountId` 不在 accounts 中的积分快照与切换日志 |
| v2 → v3 | 重建 `accounts`：删除 `creditResetAt`，新增 `lastUsedAt`；重建后 `foreign_key_check` 校验（违规仅记日志） |
| v3 → v4 | 回填 `lastUsedAt`：取每个账号非 failed 切换日志的 `MAX(createdAt)` |
| v4 → v5 | 新建 `trae_tasks`（日志采集任务与单任务消耗）及索引 |
| v5 → v6 | 新建 `project_visits`（UNIQUE(accountId, workspacePath)）及索引 |
| v6 → v7 | 新建 `projects`、`workstations`（三工位工作台，含三个 UNIQUE 约束）及索引 |

## 验证

- `Tests/CoreTests/MigrationTests.swift`（9 项）：全新库直达最新、重开不重跑且数据保留、从 v1 全链迁移、中间版本迁移、**更高版本库不被动**、**注入迁移失败后版本与数据原样**、WAL/busy_timeout/foreign_keys 配置、WAL 下备份一致性、数据库文件只读时打开显式失败。
- 兼容用例（AccountTests）：v2→v3 丢列保数据、v3→v4 回填、孤儿行清理、重开后外键仍启用。
- 备份校验（BackupRestore）：备份文件版本必须在 `[1, 7]` 且 `integrity_check = ok`、含 accounts 表，否则拒绝恢复。
