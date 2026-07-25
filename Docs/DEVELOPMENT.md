# 开发指南

这是 iOS 客户端和 Node.js 服务端放在一起的个人项目。先找到对应模块，沿用现有结构，改完跑相关检查即可。

## 目录

```text
Sources/               iOS/iPadOS 客户端
server/                Fastify、Socket.IO、PostgreSQL 服务端
Docs/                  产品、接口和运维说明
.github/workflows/     iOS 编译、服务器检查和 IPA 构建
project.yml            XcodeGen 工程配置
```

`node_modules/`、`dist/`、`DerivedData/`、uploads、数据库目录和构建产物不是源码，不需要纳入日常搜索。

## 常用入口

### iOS

| 路径 | 用途 |
|---|---|
| `Sources/App/CoupleChatApp.swift` | App 入口和前后台生命周期 |
| `Sources/App/RootTabView.swift` | 主导航 |
| `Sources/Features/Chat/` | 聊天页面、时间线、发送与媒体 |
| `Sources/Platform/Networking/` | HTTP、Socket 和重连 |
| `Sources/Platform/Persistence/` | SQLite 持久化 |
| `Sources/Platform/Sync/` | Sync V2 |
| `Sources/Features/Moments/` | 时光、相册和推荐 |
| `Sources/Features/Plans/` | 日历、提醒和备忘 |
| `Sources/Features/Daju/` | 大橘、互动和情侣卡牌 |
| `Sources/DesignSystem/` | 共用样式和组件 |

### 服务端

| 路径 | 用途 |
|---|---|
| `server/src/server.ts` | 进程启动和后台任务 |
| `server/src/app.ts` | HTTP 路由装配 |
| `server/src/socket/` | Socket 鉴权与事件 |
| `server/src/chat/` | 消息业务 |
| `server/src/sync/` | Sync V2 事件与拉取 |
| `server/src/db/` | PostgreSQL、事务和 migration |
| `server/src/upload/` | 上传和媒体访问 |
| `server/src/ai/` | Agent、Memory 和 MCP |
| `server/scripts/smoke-postgres.ts` | 服务端冒烟检查 |
| `server/deploy/` | 发布脚本和 Nginx 模板 |

## 服务端开发

环境需要 Node.js 22、npm 和本地 PostgreSQL。

```powershell
cd server
npm ci
npm run build
npm run migrate
npm start
```

本地 `.env` 使用开发数据库。调试 AI、推送或定时任务时，可以按需要关闭副作用：

```env
RUN_MIGRATIONS=false
SCHEDULED_JOBS_ENABLED=false
UPLOADS_WRITABLE=false
PUSH_ENABLED=false
```

## 常用检查

服务端改动：

```powershell
cd server
npm run check
```

修改脚本或复杂类型时再运行：

```powershell
npm run typecheck
```

iOS 在 Mac 上可以直接编译：

```bash
xcodegen generate
xcodebuild build -project CoupleChat.xcodeproj -scheme CoupleChat \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Windows 上提交后由 GitHub Actions 编译 iOS。视觉、音视频、通知和弱网行为最终看一次真机即可，不要求每次都做完整设备矩阵。

## 改代码时记住

- REST、Socket 或 Sync 字段变了，同步更新两端和 [API.md](API.md)。
- migration 按新版本追加，不修改已经在线使用的旧版本。
- 消息发送继续使用现有的 `clientId + outbox + 服务端幂等` 方案。
- SQLite 通过现有 persistence actor 访问，避免在页面或主线程直接执行 SQL。
- 聊天高频交互沿用 UIKit，普通页面沿用 SwiftUI；没有必要为了统一风格重写整个模块。
- 新功能优先放进现有 Store、Repository 或 service，只有重复明显时再增加抽象。

## 提交前

```powershell
git status --short
git diff --check
```

然后运行与本次改动相关的检查。服务器发布见 [SERVER.md](SERVER.md)，IPA 构建见 [IOS.md](IOS.md)。
