# 项目文档

`Docs/` 是项目唯一文档目录。文档只描述当前代码和运行方式；实现变化后应在同一个提交中更新对应文档。

## 推荐阅读顺序

1. [项目现状](PROJECT_STATUS.md)：先确认产品范围、完成度和已知问题。
2. [客户端体验与整体架构优化计划](REFACTOR_PLAN.md)：本轮重构的顺序、边界和验收标准。
3. [系统架构](ARCHITECTURE.md)：理解客户端、服务端、数据库和实时链路。
4. [开发指南](DEVELOPMENT.md)：建立本地调试和验证流程。
5. 按任务阅读 [接口契约](API.md)、[AI 系统](AI.md) 或 [生产部署](DEPLOYMENT.md)。

## 文档职责

| 文档 | 内容 | 何时更新 |
|---|---|---|
| `PROJECT_STATUS.md` | 功能状态、限制、待处理项 | 功能上线、下线或问题状态变化 |
| `REFACTOR_PLAN.md` | 本轮体验与架构优化的任务、顺序和验收 | 计划范围、优先级或任务完成状态变化 |
| `ARCHITECTURE.md` | 模块边界、数据流、关键约束 | 目录、职责或核心数据流变化 |
| `DEVELOPMENT.md` | 环境、命令、测试和开发规范 | 调试或构建方式变化 |
| `API.md` | REST、Socket 和消息模型 | 协议字段或事件变化 |
| `AI.md` | Agent、Memory、MCP 和调试 | AI 链路、模型或记忆规则变化 |
| `DEPLOYMENT.md` | 生产拓扑、配置、发布和备份 | 基础设施或发布流程变化 |

## 代码权威来源

文档与代码不一致时，以以下文件为准，并立即修正文档：

- iOS 工程：`project.yml`
- 服务端命令：`server/package.json`
- 环境配置：`server/src/config.ts`
- REST 注册：`server/src/app.ts` 及各模块 `routes.ts`
- Socket 契约：`server/src/contracts/realtime.ts` 与 `Sources/Core/SocketContract.swift`
- 数据库结构：`server/src/db/index.ts`
- 生产编排：`server/compose.production.yml`
