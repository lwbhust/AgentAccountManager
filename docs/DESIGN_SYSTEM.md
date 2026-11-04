# 设计系统（DESIGN SYSTEM）

> 对应实现代码：`Sources/AgentAccountManager/DesignSystem/DesignSystem.swift`。
> 原则：**沿用系统控件与语义色，规范只统一"取值"，不重造控件**。

## 1. 设计理念

1. **原生优先**：全部使用 SwiftUI/AppKit 系统字体、材质、控件；不引入第三方库。
2. **数据可扫读**：列表为扫读优化——账号名是锚点、积分是数字主角、状态收敛为轻量标记。
3. **状态有语义**：颜色永远与文字 + 图标同时出现；"数据不新鲜"是常态提示（中性），只有"异常/失败"才用警示色。
4. **密度分层**：侧边栏高密度 → 详情页中密度 → 空态低密度。

## 2. 颜色系统

全部使用系统动态语义色（自动适配深浅模式），不硬编码 RGB：

| Token | 用途 |
|---|---|
| `DS.Color.primaryText / secondaryText / tertiaryText` | 三级文字（系统 `.primary/.secondary/.tertiary` 封装） |
| `DS.Color.contentBackground` | 内容区背景（`.windowBackgroundColor`） |
| `DS.Color.cardBackground` | 卡片背景（`.controlBackgroundColor`） |
| `DS.Color.separator` | 分隔线（`separatorColor`） |
| `DS.Status.running` | 运行中（`.green`，附文字+图标） |
| `DS.Status.needsAttention` | 需要用户处理（`.orange`：待核对、确认冲突） |
| `DS.Status.failure` | 异常/失败（`.red`：查询失败、采集异常、删除） |
| `DS.Status.neutralInfo` | 中性信息（`.secondary`：数据较旧、仅供参考） |
| `DS.DataFreshness.fresh/aging/stale/unknown` | 数据新鲜度：正常→**中性灰**；超期→**浅橙提示**（仅一处小标记，禁止整页橙色） |

规则：
- 同一页面 ≤ 2 种状态色同时出现；
- 数据新鲜度不允许大面积渲染（audit P0 修正项）；
- 危险操作只允许 `.red` + 确认流程。

## 3. 字体系统

| 层级 | Token | 规格 | 用途 |
|---|---|---|---|
| L1 页面标题 | `DS.Font.pageTitle` | `.title2.weight(.semibold)` | 详情页账号名 |
| L2 区块标题 | `DS.Font.sectionHeader` | `.headline` | 卡片标题 |
| L3 正文 | `DS.Font.body` | `.body` | 键值对、列表主文本 |
| L4 辅助 | `DS.Font.secondary` | `.subheadline` + `.secondary` | 第二行信息 |
| L5 标注 | `DS.Font.caption` | `.caption` + `.tertiary` | 时间、脚注 |
| **数字** | `DS.Font.metric(size:)` | `.system(size:, weight:.semibold, design:.rounded).monospacedDigit()` | 积分、统计数字 |

规则：
- 数字永远 `monospacedDigit`，禁止普通正文加粗模拟数字；
- 同一视图内字体层级 ≤ 4 种。

## 4. 间距 / 圆角

| Token | 值 | 用途 |
|---|---|---|
| `DS.Space.xs` | 4 | 图文间隙 |
| `DS.Space.s` | 8 | 行内元素组 |
| `DS.Space.m` | 12 | 卡片内行组 |
| `DS.Space.l` | 16 | 卡片内边距 |
| `DS.Space.xl` | 20 | 页面水平边距 |
| `DS.Space.xxl` | 28 | 区块间 |

| Token | 值 | 用途 |
|---|---|---|
| `DS.Radius.s` | 6 | 小徽章、chip |
| `DS.Radius.m` | 10 | 卡片、输入组 |
| `DS.Radius.l` | 14 | 大面板 |

阴影：仅 hover 抬升（`opacity 0.08, y 2`），其余用分隔线。

## 5. 组件规范

| 组件 | 说明 |
|---|---|
| `SectionCard` | 详情页信息区块（保留，间距改用 DS） |
| `MetricValue` | 大号数字 + 单位 + 来源标签，积分页专用 |
| `StatusDot` | 轻量状态点（保留，色值改走 DS.Status） |
| `TagChip` | 胶囊标签（保留） |
| `InfoRow` | 键值行（标签 `.secondary` 值 `.body`） |
| `InlineBanner` | 提示条（保留） |
| `EmptyStateView` | 统一空态：图标 + 标题 + 说明 + 主操作 |
| `DataFreshnessBadge` | 数据新鲜度小标记（中性） |

## 6. 页面布局规范

- **主窗口**：sidebar 260–380pt；详情内容 maxWidth 860 居中。
- **工作台**：内容全宽（宽表格场景），卡片最小 340pt。
- **QuickSwitch**：固定紧凑尺寸，行高 ≤ 44pt，键盘优先。
- **Sheet 表单**：分组 Form，主操作右下 `.borderedProminent`，取消 `.bordered`。

## 7. 深浅模式规则

- 背景层级依赖系统材质（`.regularMaterial` + 分隔线描边），不使用纯黑/纯白；
- 橙/红色在深色模式下用系统动态色（自动提亮）；
- 图表颜色取 `DS.Status` 色板；
- 新增颜色必须走系统语义色或 `Color(nsColor:)`。

## 8. 交互规范

- 每屏一个主操作（Primary），次操作入菜单；
- 危险操作：独立确认对话框 + 明确列出影响范围；
- 键盘：⌘F 搜索、Esc 关闭、Enter 确认、↑↓ 列表导航；
- 空态必须给出下一步动作按钮。
