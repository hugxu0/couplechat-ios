# 系统架构

## 总体结构

```text
iOS App
  ├─ REST：登录、启动快照、历史分页、上传、提醒和每日内容
  └─ Socket.IO：实时消息、已读、在线状态、共享状态和 AI 状态
        ↓
nginx · https://hoo66.top
        ↓
Fastify + Socket.IO · 127.0.0.1:8080
  ├─ PostgreSQL：账号、消息、状态、提醒、AI Memory
  ├─ uploads/：媒体文件
  ├─ AI Agent + MCP
  └─ Bark：离线推送
```

## iOS 客户端

`Sources/App` 负责启动、通知代理和主导航。`ChatStore` 是页面使用的协调入口，内部组合三个主要状态对象：

- `AuthStore`：登录、token、当前用户和另一位用户；
- `MessageStore`：消息、同步、发送、搜索、撤回、上传和 outbox；
- `SharedStore`：共享状态、纪念日、提醒和每日内容；
- `ChatStore`：持有 Socket，分发事件并为 View 暴露统一接口。

`Sources/Core` 还包含：

- `ChatPersistence` actor：生产代码访问 SQLite 的唯一入口，实现 `ChatPersistenceProtocol`；
- `ChatLocalDatabase`：actor 内部的 SQLite connection 与 SQL 实现，页面和 Store 不直接调用；
- `ChatTimelineStore`：MainActor 上的消息窗口、已读和分页状态事实源；
- `OutboxProcessor`：串行化 outbox flush，并通过 `clientId` 读写待发项；
- `MediaUploadService`：multipart 拼装、文件流式上传和上传响应解码；
- `DailyContentRepository`、`PersonalItemsRepository`、`LocalDataRepository`：每日内容、提醒/备忘、统计/存储各自的领域入口；
- `HistorySyncCoordinator`：拥有历史与图片全量同步任务；离开存储页面不取消，显式暂停或登出才取消；
- `SocketContract`：事件名和出站 payload；
- `RealtimeConnectionCoordinator`：Socket.IO 生命周期、认证握手、重连、健康检查和连接状态；
- `HTTPClient`：可注入 REST 边界；
- `ServerConfig`：服务端地址；
- `ImageCache`、`StickerStore`、`MediaFavoriteStore`：本机媒体状态。

### 客户端目录与所有权

```text
Sources/
  App/                       App 入口、通知代理、根 Tab 与 AppState 装配
  Core/
    Models/                  跨功能领域模型
    Networking/              HTTP、Socket 契约与远端数据源
    Persistence/             SQLite actor、Keychain 与本地数据
    Chat/                    消息 facade、时间线、outbox 与同步协调
    Shared/                  账号、共享状态、每日内容与个人事项
    Media/                   图片、贴纸与收藏缓存
    Support/                 Markdown、格式化与启动快照
  DesignSystem/              视觉 token、语义页面组件、通用图片组件
  Features/
    Auth/                    登录
    Chat/
      Home/                  聊天首页装配、状态/动作模型与子视图
      Session/               会话页装配、composer、原生顶栏与控制器扩展
      Timeline/              时间线、消息 cell、滚动状态、消息动作、贴纸面板
      Media/                 图库、预览、Viewer 转场、壁纸与缩略图
      Search/                会话内搜索
      Settings/              会话详情设置
      Presentation/          互动特效与聊天呈现模型
      Fixtures/              DEBUG-only 聊天顶部视觉夹具
    Records/                 记录页、统计卡、推荐弹层、日期/纪念日编辑器
    Reminders/               提醒列表、事项卡、编辑器与 Markdown 预览
    Profile/                 我的主页
      Theme/                 主题样式
      Storage/               存储与附件管理
      Favorites/             收藏媒体
    Pet/                     当前仅展示占位的宠物页
```

`MessageStore` 与 `ChatStore` 为兼容现有页面保留 facade，但不再拥有全部底层实现。新增功能应优先进入已有的 Repository、Coordinator 或专用 Store；只有跨模块装配和向后兼容转发可以留在 facade，避免重新形成单体状态对象。

聊天入口与会话由 SwiftUI 外壳和 UIKit 高频路径组成：

```text
ChatHomeView
  → ChatView
    → ChatSessionScreen
      → ChatViewController
        ├─ UICollectionView 消息时间线
        ├─ UIKit 输入栏、键盘、附件和录音
        └─ UIKit cell 与贴纸面板
```

消息列表与输入区保持 UIKit 管理，避免在滚动、键盘和媒体交互的高频路径混用多套状态生命周期。`ChatViewController` 直接观察 `ChatTimelineStore`，不再通过父 Store 转发普通消息更新。

## 服务端

`server/src/server.ts` 负责初始化数据库、账号、AI、Fastify 与 Socket.IO。HTTP 模块由 `app.ts` 注册：

| 目录 | 职责 |
|---|---|
| `auth/` | 账号、密码、token 和 HTTP 鉴权 |
| `chat/` | 消息读写、分页、搜索、撤回和已读 |
| `socket/` | Socket 鉴权、房间、事件和在线状态 |
| `sync/` | 启动快照与消息分页 |
| `upload/` | 上传校验、签名媒体访问和清理 |
| `personalItems/` | 提醒、备忘和到期扫描 |
| `shared/` | 双方共享状态 |
| `daily/` | 日记与今日推荐接口 |
| `push/` | Bark 推送策略 |
| `ai/` | Agent、MCP、Memory、上下文和后台任务 |
| `contracts/` | 实时协议的服务端权威定义 |

数据库层按职责拆分：

```text
server/src/db/
  client.ts        PostgreSQL pool、查询与连接生命周期
  transaction.ts   事务边界
  rows.ts          数据库行类型
  migrate.ts       v1-v10 版本化 migration 与执行器
  index.ts         稳定 re-export，不承载实现
```

业务模块通过接口注入 Socket、push、repository 和调度器依赖。消息撤回后的 AI Memory 证据失效使用领域事件，Socket 路由只解析契约、调用 use case 并 emit/ack。关闭顺序由 `lifecycle/shutdown.ts` 统一管理。

## 数据与同步

服务端 PostgreSQL 是业务事实源，iOS SQLite 是设备缓存。启动流程：

1. 从 Keychain 恢复 token，并通过 `ChatPersistence` actor 读取 SQLite 快照快速出首屏。
2. 请求 `/api/bootstrap` 获取账号、最近消息、已读和共享状态。
3. 建立 Socket.IO 连接，接收后续实时增量。
4. 通过 `/api/messages` 分页补齐历史或按时间增量同步。

发送流程：

1. 客户端生成 `clientId`，将 pending 消息和 outbox 写入 SQLite。
2. 媒体消息先上传，服务端返回 `uploadId` 和签名 URL。
3. 客户端发送 `message:send`；服务端在事务中绑定上传记录并写消息。
4. ack 或 `message:new` 将 pending 消息替换为服务端消息并清除 outbox。

## 频道与权限

- 客户端频道只有 `couple` 和 `ai`。
- 服务端把个人 AI 私聊存为 `ai:<username>`。
- 公聊房间为 `channel:couple`，个人事件房间为 `user:<username>`。
- 任何 AI 工具都不能读取另一位用户的 AI 私聊。

## 不可破坏的约束

- `clientId` 是可靠发送和幂等写入的核心。
- 媒体消息必须引用服务端已有的 `uploadId`；服务端不信任客户端 URL。
- Socket 事件只在契约文件定义，不在业务代码散落新字符串。
- 列表加载必须有界，不能把完整聊天历史一次性载入内存。
- 本地数据库访问不能阻塞主线程，表结构更新必须可重复执行。
- 生产 `TOKEN_SECRET` 必须稳定，否则所有已登录设备会失效。
