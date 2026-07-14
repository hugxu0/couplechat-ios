# 悄悄话

只服务 `xu` 与 `si` 两位固定用户、支持 iPhone/iPad 多设备同步的情侣 App。客户端使用 SwiftUI + UIKit，服务端使用 Fastify、Socket.IO、PostgreSQL，并集成“大橘”AI。

生产服务：`https://hoo66.top`

## 当前能力

- 固定双账号登录、设备会话、实时在线、严格已读、撤回、引用、搜索和离线历史。
- 文字、原图、视频、语音、文件与贴纸消息；语音异步转写；Live Photo 当前按静态图处理。
- 纪念日、聊天统计、共同相册、那年今日、共享/私人日历、提醒与备忘。
- 服务端持久化的大橘状态、互动与 AI 私聊，以及可管理的结构化 Memory。
- SQLite 本地缓存、可靠发送队列、媒体缓存、Socket.IO 实时同步和 Bark 多设备通知。

公开注册、邀请码、创建或加入其他情侣空间均已删除。

## 文档

- [当前项目](Docs/current/PROJECT.md)：功能、限制、保护边界和验证基线。
- [系统架构](Docs/architecture/SYSTEM_ARCHITECTURE.md)：客户端、服务端、数据与实时链路。
- [接口契约](Docs/architecture/API.md)：当前 REST 与 Socket.IO 协议。
- [AI 系统](Docs/architecture/AI.md)：Agent、Memory、MCP 与调试。
- [开发指南](Docs/development/DEVELOPMENT.md)：本地开发、测试和构建。
- [生产部署](Docs/operations/DEPLOYMENT.md)：部署、备份和恢复。

仓库不保存历史报告、交接记录、旧计划或发布快照；Git 历史负责追溯。

## 目录

```text
CoupleChatTests/       iOS 单元测试
Docs/                  仅包含现行文档
Sources/
  App/                 App 入口与主导航
  Domain/              领域模型
  Platform/            网络、Socket、持久化、媒体与状态
  DesignSystem/        主题与通用视觉组件
  Features/            Chat、Moments、Plans、Daju、Account
server/
  deploy/              生产 nginx 配置
  scripts/             开发、部署与健康检查脚本
  src/                 服务端业务代码
.github/workflows/     独立的质量验证与快速 IPA 打包
project.yml            XcodeGen 工程定义
```

## 常用验证

```powershell
cd server
npm test
npm run build
npm run healthcheck -- https://hoo66.top
```

iOS 工程由 XcodeGen 生成。Windows 上通过 GitHub Actions 执行 SwiftLint、单元测试、Archive 和 IPA 打包。

## 不可破坏的边界

- 生产数据库与媒体目录是事实源；调试不得直接改写生产聊天或 Memory。
- 数据库迁移 v1–v27 已上线，旧迁移不可删除或改写；新变化只能追加版本。
- 现有数据库主键包含 `legacy` 字样，它们属于线上数据身份，不代表仍支持旧产品流程。
- Socket 字段变化必须同步修改 `server/src/contracts/realtime.ts`、`Sources/Platform/Networking/SocketContract.swift` 和测试。
- `.env`、`server/.data/`、`server/uploads/`、数据库备份与构建产物不得提交。
