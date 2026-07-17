# 系统架构

本文说明客户端、服务端和数据同步的当前结构与不可破坏边界。具体字段见 [API.md](API.md)，AI 内部见 [AI.md](AI.md)，关键文件位置见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 总体结构

```text
iOS / iPadOS App
  ├─ REST：登录、快照、分页、上传、业务实体
  └─ Socket.IO：消息、已读、在线状态、共享状态、AI 状态
        ↓
https://hoo66.top
        ↓
日本 Nginx 公开入口
        ↓
美国 Nginx 私有 origin
        ↓
Fastify + Socket.IO · 127.0.0.1:3000
  ├─ PostgreSQL：业务事实源
  ├─ uploads：媒体文件
  ├─ AI Agent / Memory / MCP
  ├─ 转写、提醒、推荐等调度器
  └─ Bark 推送
```

美国是唯一可写主机，日本只承担公网入口和中转，不保留 CoupleChat 项目、数据库、媒体或冷回滚资产。客户端只连接 `https://hoo66.top`。完整网络与恢复边界见 [SERVER.md](SERVER.md)。

客户端与服务端位于同一仓库，但构建和发布独立：iOS workflow 构建 App；服务端包只包含 `server/`。单仓库用于保证两端契约原子更新，不表示把 iOS 源码复制到服务器。

## iOS 客户端

### 分层

- `Sources/App`：App 入口、通知代理、Deep Link 和根 Tab。
- `Sources/Domain`：跨功能模型和协议数据。
- `Sources/Platform`：网络、SQLite、Keychain、共享状态、媒体缓存和 Sync V2。
- `Sources/Features`：聊天、时光、计划、账号和大橘功能。
- `Sources/DesignSystem`：颜色、排版、材质和语义组件。

SwiftUI 负责页面外壳和低频状态，聊天消息时间线、输入、键盘和高频媒体交互继续使用 UIKit。聊天调用链为：

```text
ChatHomeView
  → ChatView
    → ChatSessionScreen
      → ChatViewController
        ├─ UICollectionView 时间线
        ├─ UIKit 输入栏、附件和录音
        └─ UIKit cell 与贴纸面板
```

### 状态所有权

| 组件 | 所有权 |
|---|---|
| `AuthStore` | 登录、token、当前账号和另一位成员 |
| `MessageStore` | 消息、发送、撤回、搜索、上传和业务协调 |
| `ChatTimelineStore` | 当前消息窗口、分页、已读和滚动相关状态 |
| `SharedStore` | 共享状态、头像、纪念日和当前设备 Bark 配置 |
| `ChatPersistence` | 生产 SQLite 的唯一入口 |
| `OutboxProcessor` | 待发消息串行重放与完成清理 |
| `SyncV2Repository` | 持久化变更 cursor、ack 和 tombstone |
| 各领域 Repository | 相册、推荐、日历、提醒、宠物、转写、Memory 和设备会话 |

`MessageStore` 与 `ChatStore` 是页面兼容 facade；新增实现优先进入已有 Repository、Coordinator 或专用 Store。页面、MainActor 和控制器不得直接执行 SQL。

已读只由真实显示的消息 cell 驱动，并要求控制器可见且 App active。收到 Socket、恢复缓存或仅进入页面不能自动标记已读。

## 服务端

`server/src/server.ts` 只负责进程装配和生命周期；`server/src/app.ts` 注册 HTTP；Socket handler 只解析契约、授权、调用 use case 和 ack/emit。

| 领域 | 职责 |
|---|---|
| `auth` | 固定账号、密码、设备 session 和 HTTP 鉴权 |
| `chat` / `socket` / `sync` | 消息、分页、已读、实时事件和 Sync V2 |
| `upload` | 上传校验、签名媒体访问和清理 |
| `personalItems` / `calendar` | 提醒、备忘、日历、冲突和调度 |
| `albums` | 相册、媒体资产和动态分组 |
| `pet` / `daily` | 共同宠物和今日推荐 |
| `transcription` | 语音转写 provider、任务 lease 和 worker |
| `push` | Bark 收件人与投递策略 |
| `ai` | Agent、Memory、MCP、上下文和后台任务 |
| `contracts` | 服务端实时协议权威定义 |

PostgreSQL 访问集中在 `server/src/db`。当前 schema 为 v31；v1–v31 migration 不得改写，后续只能追加。业务写入通过显式事务完成；`db/index.ts` 只做稳定 re-export。

公聊事件发送到 `couple:<id>`，账号私有事件发送到 `account:<id>`。关闭顺序由 `lifecycle/shutdown.ts` 统一管理，先停止生产者，再关闭 Socket 和数据库。

## 数据事实源

- PostgreSQL 是账号、消息、已读、共享状态、业务实体和 AI Memory 的唯一事实源。
- iOS SQLite 是按账号隔离的设备缓存，不是独立真相。
- Socket.IO 是低延迟通知通道，不是唯一可靠通道；所有持久变更必须能通过 REST 或 Sync V2 补回。
- 客户端频道只有 `couple` 和 `ai`；未知频道必须拒绝或隔离，不能默认映射到 `couple`。

## 启动与接收

1. 从 Keychain 恢复设备 session，同时打开账号专属 SQLite。
2. 并行请求 `/api/bootstrap`；离线时先展示有界缓存。
3. bootstrap 成功后合并账号、每频道最近消息、已读和共享状态。
4. 建立 Socket.IO 连接，接收实时增量。
5. 通过 `/api/messages` 有界分页补齐聊天历史。
6. 启动、重连、回前台和前台轮询时通过 `/api/v2/sync` 恢复持久变更和 tombstone。

同一消息可能从 bootstrap、分页、Sync V2、Socket 或发送 ack 到达。服务端 `id` 用于去重，`clientId` 用于替换乐观消息；展示顺序不能依赖到达顺序。

最新窗口以“是否仍包含发布前已知的最新持久消息”为边界。Socket 实时来信可以先进入内存、随后完成 SQLite 持久化；这段有序提交期间新增的已确认消息仍属于最新窗口，不能因为持久锚点尚未来得及推进而把页面切成历史浏览状态。

## 可靠发送

```text
生成稳定 clientId
  → outbox 写入 SQLite
  → UI 投影 pending message
  → 媒体流式上传并取得 uploadId
  → message:send
  → 服务端事务做幂等、绑定 upload、写消息和同步事件
  → ack/message:new 返回完整消息
  → 本地持久化成功后删除 outbox
```

关键不变量：

- `clientId` 在重试、重连和重启后保持不变。
- outbox 是待发消息唯一持久事实源；pending/failed 不写入正式 messages 表。
- outbox 保存成功后才能调度网络发送。
- `message:send` ACK 返回的完整消息必须先写入 SQLite，再替换 UI pending 并推进最新窗口锚点；三者属于同一次有序提交，不能先发布成功消息后补锚点。
- 聊天时间线可以在视觉上铺到输入区后方，供系统滚动边缘与 Liquid Glass 使用；最后一条消息的安全边界必须由输入区完成布局后的真实 `frame` 换算成 `bottomInset`，不能估算键盘高度、输入框行数或面板组合高度。pending 被 ACK 服务端消息替换、输入框高度变化或键盘动画时，是否跟随最新只由既有用户阅读意图决定；只有真实拖动/减速滚动、状态栏回顶或进入历史窗口能把它改为离底，程序化布局与 `reloadData` 产生的 `scrollViewDidScroll` 不能修改该意图。
- 服务端不信任客户端媒体 URL，只接受归属正确且未被占用的 `uploadId`。
- ack 丢失允许重试；服务端必须返回同一条完整消息，不能创建重复记录。
- 客户端监听网络路径变化；Wi-Fi、蜂窝或可达性切换时废弃旧 socket，重连成功后自动重放 outbox。
- 单次发送 ACK 等待必须有独立的硬超时；短暂超时自动有限重试，达到上限后转为明确失败，不能永久停留在 pending。
- SQLite 持久化失败时不能删除 outbox 或伪装发送成功。

## 历史窗口与搜索

搜索或按日期定位到旧云端消息后，内存时间线是目标附近的有界窗口。联网时向前、向后翻页都必须先从云端取得紧邻边界的页面，再写入 SQLite 并保持可见锚点；本机因安装时间或按需搜索留下的孤立近期缓存不能作为跨越缺口的下一页。

消息搜索使用 `(ts,id)` 复合游标，服务端按两列倒序返回 `nextCursor/hasMore`，客户端显式“加载更多”并按消息 id 去重。搜索命中在进入上下文前写入本地，但搜索列表分页与聊天上下文分页是两条独立链路。

## 媒体渐进读取

签名媒体和兼容媒体入口都提供单段 HTTP Range。除普通起止范围外，文件尾部的 suffix Range 是远程 MP4 快速读取 `moov` 元数据的必要契约；解析错误会让系统播放器退化为整段下载。客户端全屏播放只使用 `AVPlayer` 的分段缓冲和原生加载/失败状态，视频缩略图不得在后台回退为完整文件下载并与播放器争抢带宽。

## Sync V2

`GET /api/v2/sync` 返回明确的 `protocolVersion: 2`、有序 `events`、`nextCursor` 和 `hasMore`。客户端只有在整批事件完成协议/频道校验并成功提交 SQLite 后，才保存 cursor 并发送 ack。设备 ack 只单调增加。

### 提交顺序

PostgreSQL sequence 的分配顺序不等于事务提交顺序。所有创建同步事件的事务必须在第一次分配序号前取得同一个 transaction-level advisory lock：

1. lock 在事务内持有到 commit/rollback；
2. 取得 lock 后才调用 `nextval` 和写事件；
3. 单事务多事件连续分配；
4. rollback 可留下空洞，客户端不要求序号连续；
5. 运行时代码不得伪造 `DatabaseTransaction` 或绕过统一 `appendSyncEvent` 边界。

发布该边界的变化时必须先停止旧 writer；新旧 writer 重叠会破坏顺序保证。

### SQLite 提交

- `prepare/bind/step/finalize` 错误都必须传播为可观察失败。
- 批量 upsert 与 cursor 更新处于同一事务。
- 任一消息失败则整批 rollback，cursor/ack 不推进。
- 无法确认 rollback 后已恢复 autocommit 时，立即失效连接。
- 磁盘满、锁、约束冲突和损坏不能当作空结果。

## 历史分页

`/api/messages` 支持 `before`、`after`、`after + before`、`since` 和 `around`。方向边界当前仍只有毫秒 `ts`；同毫秒多消息不是稳定游标，是 [PROJECT.md](PROJECT.md) 中的 `SYNC-002`。目标是统一使用 `(ts,id)` 或服务端序号。

完整历史始终有界加载，不能一次把所有聊天记录读入内存。

## 权限边界

- `couple` 数据按 `couple_id` 共享。
- `ai` 私聊由 `conversation.owner_account_id` 所有，只对当前账号可见。
- 个人提醒、设备、推荐读取状态和私有 Memory 按 `account_id` 隔离。
- 任何 AI 工具都不能读取另一账号的 AI 私聊。
- `TOKEN_SECRET` 必须稳定，否则所有现有登录会话失效。

## 当前验证边界

仓库已移除客户端和服务端单元测试。服务端 `npm run check` 当前覆盖生产编译和 embedded PostgreSQL smoke，iOS CI 覆盖 SwiftLint、结构护栏和 generic iOS 编译。

涉及以下场景时必须在隔离环境或真机补充实际验证：反序提交、rollback 空洞、并发轮询、Socket 断线补回、Socket/Sync 重复事件、SQLite 中途失败、同毫秒分页、未知协议/频道、`clientId` 超时重试以及多设备账号切换。
