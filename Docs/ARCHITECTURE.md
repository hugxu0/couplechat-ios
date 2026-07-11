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

- `ChatLocalDatabase`：SQLite 缓存、读状态、共享状态和发送队列；
- `HistorySyncCoordinator`：拥有历史与图片全量同步任务；离开存储页面不取消，显式暂停或登出才取消；
- `SocketContract`：事件名和出站 payload；
- `HTTPClient`：可注入 REST 边界；
- `ServerConfig`：服务端地址；
- `ImageCache`、`StickerStore`、`MediaFavoriteStore`：本机媒体状态。

聊天会话由 SwiftUI 外壳和 UIKit 高频路径组成：

```text
ChatView
  → ChatV2Screen
    → ChatViewController
      ├─ UICollectionView 消息时间线
      ├─ UIKit 输入栏、键盘、附件和录音
      └─ UIKit cell 与贴纸面板
```

消息列表与输入区保持 UIKit 管理，避免在滚动、键盘和媒体交互的高频路径混用多套状态生命周期。

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

## 数据与同步

服务端 PostgreSQL 是业务事实源，iOS SQLite 是设备缓存。启动流程：

1. 从 Keychain 恢复 token，并读取 SQLite 快照快速出首屏。
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
