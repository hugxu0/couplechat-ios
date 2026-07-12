# 悄悄话

当前生产后端已升级为可注册/邀请码配对的 V2，现有两位 legacy 用户继续无感使用；V2 iOS 候选仍需在真机安装回归。客户端使用 SwiftUI + UIKit，服务端使用 Fastify + Socket.IO + PostgreSQL，并集成“大橘”AI。

生产服务地址：`https://hoo66.top`

## 当前能力

- legacy 快捷登录、V2 注册/邀请码配对、多设备会话、实时在线状态、严格已读、硬删除撤回、引用回复和消息搜索
- 文字、图片、视频、语音、文件和贴纸；Live Photo 当前按静态图发送，配对资源协议仍保留
- 设备端 SQLite 缓存、离线历史、可靠发送队列和媒体缓存
- 纪念日、共同相册/那年今日、共享/私人日历、提醒、备忘、共同宠物、聊天统计、主题和聊天壁纸
- `couple` 公聊与个人 `ai` 私聊
- legacy `xu/si` 的完整大橘 Agent/图片理解/联网查询/结构化 Memory/确认卡；新情侣当前为无历史基础 AI
- Docker Compose 生产部署，PostgreSQL 与媒体文件持久化

## 快速入口

- [文档导航](Docs/README.md)：新开发者或 AI 的阅读起点
- [AI 接手说明](Docs/AI_HANDOFF.md)：当前进度、接手步骤、验证记录和下一任务提示词
- [项目现状](Docs/PROJECT_STATUS.md)：已实现功能、限制和待处理问题
- [V2 产品计划](Docs/V2_PRODUCT_PLAN.md)：当前候选、完整 MVP 和剩余增强
- [V2 技术架构](Docs/V2_ARCHITECTURE.md)：所有权、同步、迁移和发布路线
- [R0-R8 历史重构计划](Docs/REFACTOR_PLAN.md)：V1 发布阶段的历史任务与验收证据
- [系统架构](Docs/ARCHITECTURE.md)：前后端模块、数据流和关键约束
- [开发指南](Docs/DEVELOPMENT.md)：本地调试、构建和日常验证
- [接口契约](Docs/API.md)：REST 与 Socket.IO 协议
- [AI 系统](Docs/AI.md)：Agent、MCP、Memory 和调试方式
- [生产部署](Docs/DEPLOYMENT.md)：RFCHost 的运行、更新和备份
- [R0-R8 完成报告](Docs/RELEASE_REPORT_2026-07-12.md)：本轮架构、体验、验证和上线结果

## 仓库结构

```text
CoupleChatTests/       iOS 日常单元测试
CoupleChatUITests/     DEBUG 视觉夹具 UI 测试
Docs/                  项目唯一文档目录
Sources/
  App/                 App 入口、启动与主导航
  Core/                状态、网络、Socket、本地数据库和模型
  DesignSystem/        主题和通用视觉组件
  Features/            登录配对、聊天、时光、计划、宠物、个人中心与设备/Memory 设置
server/
  deploy/              当前生产 nginx 配置
  scripts/             日常开发与健康检查脚本
  src/                 服务端业务代码
.github/workflows/     iOS 构建与测试
project.yml            XcodeGen 工程定义
```

## 常用命令

当前 V2 工作树需要 v22 schema，不能直接在仍处于 v10 发布边界的生产库上启动。生产只做只读连接检查：

```powershell
cd server
npm install
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/dev-cloud-db.ps1 -CheckOnly
```

服务端功能调试使用从备份恢复并迁移到 v22 的隔离 PostgreSQL；`dev:cloud-db` 已强制关闭 migration，schema 不匹配时会安全退出。

后端日常验证：

```powershell
cd server
npm test
npm run build
npm run healthcheck -- https://hoo66.top
```

iOS 工程由 XcodeGen 生成。Windows 上通过 GitHub Actions 执行 SwiftLint、单元测试和 Archive，具体见 [开发指南](Docs/DEVELOPMENT.md)。

## 重要约束

- `xu` 与 `si` 是 legacy 迁移标识，现有生产数据依赖它们；V2 新账号不得继续写死这两个用户名。
- 生产数据库是线上事实源；开发与 AI 调试不得直接写生产聊天或 Memory，必须使用隔离恢复库。
- `.env`、`server/.data/`、`server/uploads/` 和任何数据库备份不得提交。
- Socket 字段变化必须同时更新 `server/src/contracts/realtime.ts` 与 `Sources/Core/Networking/SocketContract.swift`。
- 生产已执行 v1–v22，全部 migration 自 2026-07-13 起冻结；后续数据库变化只能追加新版本。
