# 悄悄话

面向两位固定用户的原生 iOS 私密聊天应用。客户端使用 SwiftUI + UIKit，服务端使用 Fastify + Socket.IO + PostgreSQL，并集成“大橘”AI Agent。

生产服务地址：`https://hoo66.top`

## 当前能力

- 双人登录、实时在线状态、已读、撤回、引用回复和消息搜索
- 文字、图片、视频、语音、文件、贴纸和 Live Photo
- 设备端 SQLite 缓存、离线历史、可靠发送队列和媒体缓存
- 纪念日、提醒、备忘、聊天统计、主题和聊天壁纸
- `couple` 公聊与个人 `ai` 私聊
- 大橘 Agent、图片理解、联网查询、结构化 Memory 和确认卡
- Docker Compose 生产部署，PostgreSQL 与媒体文件持久化

## 快速入口

- [文档导航](Docs/README.md)：新开发者或 AI 的阅读起点
- [项目现状](Docs/PROJECT_STATUS.md)：已实现功能、限制和待处理问题
- [系统架构](Docs/ARCHITECTURE.md)：前后端模块、数据流和关键约束
- [开发指南](Docs/DEVELOPMENT.md)：本地调试、构建和日常验证
- [接口契约](Docs/API.md)：REST 与 Socket.IO 协议
- [AI 系统](Docs/AI.md)：Agent、MCP、Memory 和调试方式
- [生产部署](Docs/DEPLOYMENT.md)：RFCHost 的运行、更新和备份

## 仓库结构

```text
CoupleChatTests/       iOS 日常单元测试
Docs/                  项目唯一文档目录
Sources/
  App/                 App 入口、启动与主导航
  Core/                状态、网络、Socket、本地数据库和模型
  DesignSystem/        主题和通用视觉组件
  Features/            登录、聊天、记录、提醒、宠物、个人中心
server/
  deploy/              当前生产 nginx 配置
  scripts/             日常开发与健康检查脚本
  src/                 服务端业务代码
.github/workflows/     iOS 构建与测试
project.yml            XcodeGen 工程定义
```

## 常用命令

Windows 本地后端调试使用 SSH 隧道连接生产数据库，安全开关会关闭定时任务、推送和上传写入：

```powershell
cd server
npm install
npm run dev:cloud-db
```

后端日常验证：

```powershell
cd server
npm test
npm run build
npm run healthcheck -- https://hoo66.top
```

iOS 工程由 XcodeGen 生成。Windows 上通过 GitHub Actions 执行 SwiftLint、单元测试和 Archive，具体见 [开发指南](Docs/DEVELOPMENT.md)。

## 重要约束

- `xu` 与 `si` 是固定账号标识，业务数据依赖它们，不要随意更名。
- 生产数据库是唯一服务端数据源；本地调试会真实读写生产聊天与 AI Memory。
- `.env`、`server/.data/`、`server/uploads/` 和任何数据库备份不得提交。
- Socket 字段变化必须同时更新 `server/src/contracts/realtime.ts` 与 `Sources/Core/SocketContract.swift`。
- 数据库结构只追加新的版本化变更，不修改已经执行过的版本。
