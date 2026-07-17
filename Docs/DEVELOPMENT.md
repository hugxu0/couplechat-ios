# 开发指南与文件地图

本文负责仓库结构、关键入口、开发环境、验证命令和代码约定。产品状态见 [PROJECT.md](PROJECT.md)，架构边界见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 开工检查

```powershell
git rev-parse --show-toplevel
git status --short --branch
git rev-parse HEAD
```

必须在同时包含 `Sources/` 与 `server/` 的真实单仓库中工作。无 `.git` 的复制目录只是快照，不能作为开发或发布事实源。先阅读根 `AGENTS.md`、本目录 [README.md](README.md) 和 [PROJECT.md](PROJECT.md)。

## 仓库结构

```text
Sources/               iOS/iPadOS 客户端源码
server/                Fastify/Socket.IO/PostgreSQL 服务端
Docs/                  当前 8 份权威文档
.github/workflows/     快速验证和 unsigned IPA workflow
.github/scripts/       公开仓库扫描与 IPA 下载校验工具
project.yml            XcodeGen 工程定义
AGENTS.md               全仓库安全、验证和交付规则
```

仓库不保留客户端或服务端单元测试目录。构建产物、`node_modules/`、`dist/`、`DerivedData/`、uploads、数据库和 `.data/` 不属于源码。

## 客户端关键位置

| 路径 | 用途 |
|---|---|
| `project.yml` | iOS 版本、Bundle ID、依赖、资源和 target 权威定义 |
| `Sources/App/CoupleChatApp.swift` | App 入口与依赖装配 |
| `Sources/App/RootTabView.swift` | 根导航与五个主入口 |
| `Sources/Domain/Models/` | 消息、相册、日历、宠物、Memory 等领域模型 |
| `Sources/Platform/Networking/HTTPClient.swift` | 可注入 REST 边界 |
| `Sources/Platform/Networking/SocketContract.swift` | iOS Socket 事件和请求结构 |
| `Sources/Platform/Networking/RealtimeConnectionCoordinator.swift` | Socket 生命周期、重连和健康检查 |
| `Sources/Platform/Networking/RealtimeEventRouter.swift` | 实时事件分发与频道校验 |
| `Sources/Platform/Persistence/ChatPersistence.swift` | SQLite actor 和生产持久化唯一入口 |
| `Sources/Platform/Persistence/ChatLocalDatabase.swift` | SQLite schema 与 SQL 实现，仅由 actor 使用 |
| `Sources/Platform/State/AuthStore.swift` | 登录、session 和账号状态 |
| `Sources/Platform/State/SharedStore.swift` | 共享状态和当前设备配置 |
| `Sources/Platform/Sync/SyncV2Repository.swift` | Sync V2 cursor、ack 和事件应用 |
| `Sources/Features/Chat/Data/MessageStore.swift` | 消息页面状态和业务协调 |
| `Sources/Features/Chat/Data/ChatTimelineStore.swift` | 当前时间线窗口和分页状态 |
| `Sources/Features/Chat/Data/OutboxProcessor.swift` | 待发消息串行重放 |
| `Sources/Features/Chat/Data/PendingMessageFactory.swift` | 统一生成乐观消息和 outbox 项 |
| `Sources/Features/Chat/Session/` | UIKit 会话控制器、输入、附件和录音 |
| `Sources/Features/Chat/Timeline/` | Collection View cell、布局、消息动作和贴纸面板 |
| `Sources/Features/Moments/` | 相册、动态、推荐和聊天统计 |
| `Sources/Features/Plans/` | 日历、提醒和备忘 |
| `Sources/Features/Account/` | 设置、Memory、存储、设备和收藏 |
| `Sources/Features/Daju/` | 大橘 3D、互动和 AI 私聊入口 |
| `Sources/DesignSystem/DS.swift` | 颜色、间距、圆角、字体、动画和 UIKit token |
| `Sources/DesignSystem/AppSemanticComponents.swift` | 跨页面语义组件 |

普通页面和小组件不逐一登记；新增模块时只在其成为跨功能入口或事实所有者后更新本表。

## 服务端关键位置

| 路径 | 用途 |
|---|---|
| `server/src/server.ts` | 进程装配、调度器启动和生命周期 |
| `server/src/app.ts` | Fastify 路由注册 |
| `server/src/config.ts` | 环境变量解析和运行配置 |
| `server/src/contracts/realtime.ts` | 服务端 Socket 协议权威定义 |
| `server/src/db/client.ts` | PostgreSQL pool 与连接生命周期 |
| `server/src/db/transaction.ts` | 事务边界 |
| `server/src/db/migrate.ts` | v1–v31 migration；只能追加 |
| `server/src/sync/events.ts` | Sync 事件统一写入和提交顺序保护 |
| `server/src/sync/v2Routes.ts` | Sync V2 拉取与 ack |
| `server/src/chat/messageService.ts` | 消息读写、分页、搜索和撤回 |
| `server/src/socket/realtime.ts` | Socket 鉴权、事件处理和广播 |
| `server/src/upload/` | 上传、签名媒体访问与清理 |
| `server/src/ai/` | Agent、Memory、MCP、日总览、engagement |
| `server/src/ai/pipeline.ts` | 主人消息后三线调度（上下文 / Memory / 回复） |
| `server/src/ai/imageAttachment.ts` | 多模态看图附着（问题+图进主模型） |
| `server/src/ai/conversation/context.ts` | day-digest-v2 与热窗口 |
| `server/src/ai/engagement.ts` | 公聊冲突/搭话 |
| `server/src/ai/textSignals.ts` | 低信息量文本判定 |
| `server/src/*/routes.ts` | 各业务 REST 入口 |
| `server/scripts/smoke-postgres.ts` | embedded PostgreSQL 当前行为 smoke |
| `server/deploy/` | 固定 SHA 的发布脚本和安全模板 |

## 环境要求

- Windows 11、PowerShell、Node.js 22、npm：服务端开发和验证。
- macOS、Xcode 26.3、XcodeGen、SwiftLint：iOS 本地构建。
- GitHub Actions：Windows 工作流下的 iOS 编译和 unsigned IPA 入口。

安装服务端依赖：

```powershell
cd server
npm ci
```

## 本地服务端

本地 `.env` 必须指向隔离 PostgreSQL，并至少提供稳定的 `TOKEN_SECRET`、`DATABASE_URL` 和包含 `xu/si` 的 `COUPLECHAT_ACCOUNTS`。

```powershell
cd server
npm run build
npm run migrate
npm start
```

生产 Web 进程必须设置 `RUN_MIGRATIONS=false`。功能调试只能使用本地临时数据库或隔离恢复库；不得把开发进程连接生产数据库。

隔离调试建议固定关闭副作用：

```env
RUN_MIGRATIONS=false
SCHEDULED_JOBS_ENABLED=false
UPLOADS_WRITABLE=false
PUSH_ENABLED=false
```

AI key 和模型配置只保存在被 Git 忽略的受信本机文件，不写入仓库。AI 调试页仅可在隔离数据库和 loopback 地址使用，详见 [AI.md](AI.md)。

## 日常验证

服务端：

```powershell
cd server
npm run check
npm run typecheck
```

- `npm run check`：生产编译 + embedded PostgreSQL smoke。
- `npm run typecheck`：额外检查 `scripts/` 等非生产 TypeScript。

iOS（Mac）：

```bash
xcodegen generate
xcodebuild build -project CoupleChat.xcodeproj -scheme CoupleChat \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

默认 GitHub workflow 执行公开仓库扫描、服务端检查、SwiftLint、结构护栏和 generic iOS 编译。unsigned IPA、签名和安装见 [IOS.md](IOS.md)。

## 修改规则

### 跨端协议

1. 修改 `server/src/contracts/realtime.ts` 或对应 REST schema。
2. 修改 `Sources/Platform/Networking/SocketContract.swift` 和客户端模型。
3. 更新调用方、后端 smoke/静态检查和 [API.md](API.md)。
4. 涉及同步时同时核对 [ARCHITECTURE.md](ARCHITECTURE.md) 中的 cursor、事务和频道不变量。

### 数据库与同步

- migration 只追加，不能修改 v1–v31。
- 所有 Sync 事件经过统一写入边界，并在分配序号前取得 advisory lock。
- SQLite 只通过 `ChatPersistenceProtocol` 异步访问；MainActor 和页面不得直接执行 SQL。
- cursor/ack 只有在整批协议校验和本地事务成功后推进。
- `clientId + outbox + 服务端幂等` 是可靠发送核心，不得拆散。

### 客户端界面

- 新页面观察真正拥有状态的 Store/Repository，不继续扩大 `ChatStore`。
- 高频聊天路径保持 UIKit，不进行大爆炸重写。
- 可点击媒体由明确的 Button/control 承载；预览锚点不得接收触摸或覆盖文案操作区。
- 视觉 token 从 `DS.swift` 读取；重复模式先抽语义组件。
- 新界面检查深色模式、Dynamic Type、VoiceOver、Reduce Motion、iPad 分屏和指针/键盘。

## 提交前

```powershell
git status --short
git diff --check
cd server
npm run check
```

iOS 改动还需等待对应 GitHub Actions 编译；交互、音视频、通知和签名变化必须列出真机验证结果。生产部署必须另外遵守 [SERVER.md](SERVER.md)。
