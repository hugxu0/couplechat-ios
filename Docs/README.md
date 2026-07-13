# 项目文档

`Docs/` 是项目唯一文档目录，按“现在要看什么”而不是按历史编号组织。当前状态和产品计划是现行事实；`history/` 只用于追溯，不得覆盖当前结论。

## 推荐阅读顺序

1. [当前状态](current/STATUS.md)：先确认产品范围、完成度和已知限制。
2. [AI 接手说明](current/HANDOFF.md)：确认当前分支、验证结果和下一步边界。
3. [产品计划](product/PRODUCT_PLAN.md)：查看功能边界、优先级和验收标准。
4. [系统架构](architecture/SYSTEM_ARCHITECTURE.md)：理解客户端、服务端、数据库和实时链路。
5. [V2 技术架构](architecture/V2_ARCHITECTURE.md)：理解多情侣、多设备、同步和迁移路线。
6. 按任务阅读 [接口契约](architecture/API.md)、[AI 系统](architecture/AI.md)、[开发指南](development/DEVELOPMENT.md) 或 [生产部署](operations/DEPLOYMENT.md)。
7. 需要追溯时再阅读 [历史重构计划](history/REFACTOR_PLAN.md)、[发布报告](history/RELEASE_REPORT_2026-07-12.md) 和 [发布证据](evidence/RELEASE_MATRIX.md)。

## 目录职责

| 目录 | 内容 | 更新规则 |
|---|---|---|
| `current/` | 当前状态、限制、验证结果和 AI 接手入口 | 每批功能或发布变化都要更新 |
| `product/` | 产品边界、交互设计、功能计划和验收 | 产品决策变化时更新 |
| `architecture/` | 系统架构、数据模型、API、Socket 和 AI 链路 | 代码边界或协议变化时更新 |
| `development/` | 本地调试、测试、构建和提交规范 | 命令或工具链变化时更新 |
| `operations/` | 生产拓扑、部署、备份和回滚 | 线上流程变化时更新 |
| `history/` | 已完成阶段的计划和报告 | 只追加勘误，不表达当前状态 |
| `evidence/` | 发布矩阵、性能测量和其他可复核证据 | 每次验证或基准变化时更新 |

## 文档规则

- 新文档先判断它属于哪个生命周期目录；不要再把功能说明直接放在 `Docs/` 根目录。
- 文档中的功能状态必须以代码和最近一次验证为依据；计划中的能力明确标注“未完成”。
- 协议变化必须同时更新 `architecture/API.md`、两端契约和测试。
- 每次改代码，若影响行为、命令、接口或发布流程，应在同一提交更新对应文档。
- 历史文档可以保留原始背景，但不能作为当前实现的权威来源。

## 代码权威来源

文档与代码不一致时，以以下文件为准，并立即修正文档：

- iOS 工程：`project.yml`
- 服务端命令：`server/package.json`
- 环境配置：`server/src/config.ts`
- REST 注册：`server/src/app.ts` 及各模块 `routes.ts`
- Socket 契约：`server/src/contracts/realtime.ts` 与 `Sources/Core/Networking/SocketContract.swift`
- 数据库结构：`server/src/db/migrate.ts`
- 生产编排：`server/compose.production.yml`
