# 系统架构

## 总体结构

```text
iOS App
  ├─ REST：登录、启动快照、历史分页、上传、提醒和每日内容
  └─ Socket.IO：实时消息、已读、在线状态、共享状态和 AI 状态
        ↓
日本 RFCHost nginx · https://hoo66.top（TLS 入口与反向代理）
        ↓
美国 RackNerd nginx · https://chat.huhuhu.top（私有 origin）
        ↓
Fastify + Socket.IO · 127.0.0.1:3000
  ├─ PostgreSQL：账号、消息、状态、提醒、AI Memory
  ├─ uploads/：媒体文件
  ├─ AI Agent + MCP
  └─ Bark：离线推送
```

美国服务器是唯一可写主机；日本服务器不运行第二套后端或数据库。日本到美国 origin 使用 TLS 与独立代理密钥，直接访问 origin 会返回 `403`。

## iOS 客户端

`Sources/App` 负责启动、通知代理和主导航。根导航使用系统 `sidebarAdaptable` Tab：iPhone 显示底栏，iPad 按可用宽度转为侧栏。`ChatStore` 是页面使用的协调入口，内部组合主要状态对象和 Repository：

- `AuthStore`：登录、token、当前用户和另一位用户；
- `MessageStore`：消息、同步、发送、搜索、撤回、上传和 outbox；
- `SharedStore`：共享状态、纪念日、提醒和每日内容；
- `StickerStore`：自定义表情的账号级离线缓存；固定总库、自建分组和排序通过账号专属 shared-state key 同步到同账号所有设备，两个账号互不覆盖；
- `AIMemoryRepository`：Memory 控制中心的列表、证据、纠正、删除和立即整理；
- `MomentsRepository`：共同相册、聊天媒体入册、注脚与那年今日；
- `CalendarRepository`：共享/私人日历、版本冲突与完成状态；
- `CouplePetRepository`：服务端宠物快照和幂等互动；
- `VoiceTranscriptRepository`：转写查询与失败重试；
- `SyncV2Repository`：持久化变更 cursor、ack 和离线删除恢复；
- `DeviceSessionRepository`：多设备登录、列表和撤销；
- `ChatStore`：持有 Socket，分发事件并为 View 暴露统一接口。

`Sources/Platform` 与 `Features/*/Data` 承载运行时实现：

- `ChatPersistence` actor：生产代码访问 SQLite 的唯一入口，实现 `ChatPersistenceProtocol`；
- `ChatLocalDatabase`：actor 内部的 SQLite connection 与 SQL 实现，页面和 Store 不直接调用；
- `ChatTimelineStore`：MainActor 上的消息窗口、已读和分页状态事实源；
- `OutboxProcessor`：串行化 outbox flush，并通过 `clientId` 读写待发项；
- `MediaUploadService`：multipart 拼装、文件流式上传和上传响应解码；
- `DailyContentRepository`、`PersonalItemsRepository`、`LocalDataRepository`：每日内容、提醒/备忘、统计/存储各自的领域入口；
- `HistorySyncCoordinator`：拥有历史与图片全量同步任务；离开存储页面不取消，显式暂停或登出才取消；
- `SocketContract`：事件名和出站 payload；
- `RealtimeConnectionCoordinator`：Socket.IO 生命周期、认证握手、重连、健康检查和连接状态；
- `RealtimeEventRouter`：消息、已读、AI、presence 和共享状态等领域事件路由；
- `HTTPClient`：可注入 REST 边界；
- `ServerConfig`：服务端地址；
- `ImageCache`、`StickerStore`、`MediaFavoriteStore`：本机媒体状态；动态贴纸保留原始 GIF/WebP 数据，表情库与收藏均按登录账号分区；同账号多设备的表情变更以记录修订和删除墓碑合并，避免并发添加丢失或旧设备复活已删除内容。

### 客户端目录与所有权

```text
Sources/
  App/                       App 入口、通知代理与根 Tab
  Domain/
    Models/                  跨功能领域模型和协议数据
  Platform/
    Networking/              HTTP、Socket 契约与远端数据源
    Persistence/             SQLite actor、Keychain 与本地数据
    State/                   登录与共享状态
    Media/                   图片、贴纸与收藏缓存
    Support/                 Markdown、格式化与启动快照
    Sync/                    Sync V2 持久化游标与 ack
  DesignSystem/              视觉 token、语义页面组件、通用图片组件
  Features/
    Auth/                    固定账号登录界面
    Chat/
      Data/                  消息 facade、时间线、outbox、转写与同步协调
      Home/                  聊天首页装配、状态/动作模型与子视图
      Session/               会话页装配、composer、原生顶栏与控制器扩展
      Timeline/              时间线、消息 cell、滚动状态、消息动作、贴纸面板
      Media/                 图库、预览、Viewer 转场、壁纸与缩略图
      Search/                会话内搜索
      Settings/              会话详情设置
      Presentation/          互动特效与聊天呈现模型
    Moments/
      Data/                  共同相册、那年今日、统计数据源
    Plans/
      Data/                  日历、提醒与备忘数据源
    Account/
      Data/                  Memory、设备会话数据源
      Memory/                Memory 控制中心、详情与语义组件
      Theme/                 主题样式
      Storage/               存储与附件管理
      Favorites/             收藏媒体
    Daju/
      Data/                  共同宠物数据源
                            共同宠物、互动、模型和大橘私聊入口
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

已读只由真实显示的 collection view message cell 驱动，同时要求聊天控制器当前可见、App 处于 active；收到 Socket、恢复缓存或仅进入页面都不会自动已读。聊天容器与媒体网格使用当前窗口尺寸，支持 iPad Split View 与 Stage Manager。

共同相册时间线复用 `ChatMediaViewerCoordinator`，但浏览集合只取被点击动态中的媒体。媒体缩略图由 SwiftUI `Button` 统一承载轻点与 `contextMenu` 长按，图片/视频在按钮内部按方形裁切；用于缩回原位置的 UIKit source anchor 只记录几何位置并关闭 hit testing。文案、编辑与更多操作位于媒体网格上方的独立布局行，不能用扩大的 `contentShape` 或跨层 `zIndex` 覆盖媒体命中区。

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
| `transcription/` | OpenAI-compatible 转写 provider、job lease 与 worker |
| `albums/` | 共同相册、媒体资产、注脚和那年今日 |
| `calendar/` | 共享/私人日历、时区、完成和版本冲突 |
| `pet/` | 共同宠物状态衰减、五种互动、冷却与幂等同步 |
| `daily/` | 最近 30 天大橘日记接口 |
| `push/` | Bark 推送策略 |
| `ai/` | Agent、MCP、Memory、上下文和后台任务 |
| `contracts/` | 实时协议的服务端权威定义 |

数据库层按职责拆分：

```text
server/src/db/
  client.ts        PostgreSQL pool、查询与连接生命周期
  transaction.ts   事务边界
  rows.ts          数据库行类型
  migrate.ts       v1-v25 版本化 migration 与受控执行器（仅追加，历史版本保持不变）
  index.ts         稳定 re-export，不承载实现
```

业务模块通过接口注入 Socket、push、repository 和调度器依赖。消息撤回先在客户端时间线乐观隐藏；服务端事务内硬删除消息、附件关系、引用预览、Memory 证据和孤立 Memory，提交后立即确认，物理文件与 Trace 脱敏在持久化清理队列中后台完成。Socket 路由只解析契约、调用 use case 并 emit/ack。Bark 提醒用 `reminder_bark_deliveries` 持久化投递结果。关闭顺序由 `lifecycle/shutdown.ts` 统一管理。

## 数据与同步

服务端 PostgreSQL 是业务事实源，iOS SQLite 是设备缓存。启动流程：

1. 从 Keychain 恢复 token，并通过 `ChatPersistence` actor 读取 SQLite 快照快速出首屏。
2. 请求 `/api/bootstrap` 获取账号、最近消息、已读和共享状态。
3. 建立 Socket.IO 连接，接收后续实时增量。
4. 通过 `/api/messages` 分页补齐历史或按时间增量同步。
5. 通过 `/api/v2/sync` 在启动、重连、回前台和前台轮询时恢复持久化变更与删除 tombstone。

发送流程：

1. 客户端生成 `clientId`，将 pending 消息和 outbox 写入 SQLite。
2. 媒体消息先上传，服务端返回 `uploadId` 和签名 URL。
3. 客户端发送 `message:send`；服务端在事务中绑定上传记录并写消息。
4. ack 或 `message:new` 将 pending 消息替换为服务端消息并清除 outbox。

## 频道与权限

- 客户端频道只有 `couple` 和 `ai`。
- 服务端把个人 AI 私聊兼容投影为 `ai:<username>`，事实所有权由 `conversation.owner_account_id` 决定。
- 公聊房间为 `couple:<coupleId>`，个人事件房间为 `account:<accountId>`。
- 任何 AI 工具都不能读取另一位用户的 AI 私聊。
- `xu/si` 使用完整 Agent + Memory 工具；共享与私人 AI 数据继续通过 conversation/account/couple ownership 约束。

## 不可破坏的约束

- `clientId` 是可靠发送和幂等写入的核心。
- 媒体消息必须引用服务端已有的 `uploadId`；服务端不信任客户端 URL。
- Socket 事件只在契约文件定义，不在业务代码散落新字符串。
- 列表加载必须有界，不能把完整聊天历史一次性载入内存。
- 本地数据库访问不能阻塞主线程，表结构更新必须可重复执行。
- 生产 `TOKEN_SECRET` 必须稳定，否则所有已登录设备会失效。
