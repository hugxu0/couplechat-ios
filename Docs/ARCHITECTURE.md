# 系统架构

字段见 [API.md](API.md)，AI 内部见 [AI.md](AI.md)，部署见 [SERVER.md](SERVER.md)。

## 总体结构

```text
iOS / iPadOS App（REST + Socket.IO）
  → https://hoo66.top
  → 日本 RFC Nginx 公开入口（TLS、WebSocket 转发，不存业务数据）
  → Tailscale 私网
  → 小米 10 Ubuntu chroot · Tailscale Serve :13000 → 127.0.0.1:3000（Fastify + Socket.IO）
      ├─ PostgreSQL（唯一事实源）
      ├─ uploads/（媒体文件）
      ├─ AI Agent / Memory / MCP
      └─ 转写、提醒、推荐等调度器 + Bark 推送
```

单仓库保证两端契约原子更新；iOS 与服务端分别构建发布。

## iOS 客户端

分层：`App`（入口/深链/根 Tab）、`Domain`（模型）、`Platform`（网络/SQLite/
媒体缓存/Sync）、`Features`（五个 tab）、`DesignSystem`。SwiftUI 管页面外壳，
聊天时间线、输入和高频媒体交互用 UIKit。

| 状态所有者 | 职责 |
|---|---|
| `AuthStore` | 登录、token、账号、session generation |
| `MessageStore` | 消息、发送、撤回、搜索、上传协调 |
| `ChatTimelineStore` | 当前消息窗口、分页、已读、滚动 |
| `SharedStore` | 共享状态、头像、纪念日、Bark 配置 |
| `ChatPersistence` | SQLite 唯一入口（actor） |
| `OutboxProcessor` | 待发消息串行重放 |
| 各领域 Repository | 相册、推荐、日历、提醒、宠物、卡牌、转写、Memory |

**账号边界**：`ChatPersistence` 每次激活生成不可复用的 scope，所有读写都校验它
（接口只有带 scope 的版本）。`AuthStore` 在登录/退出时推进 generation，旧账号
未返回的任务只能被丢弃，不能触碰新账号的数据。

**已读**只由真实显示的消息 cell 驱动（控制器可见且 App active），收到 Socket
或恢复缓存不自动标已读。

## 服务端

`server.ts` 装配进程，`app.ts` 注册 HTTP，Socket handler 只做解析、授权、调用
use case。领域目录：`auth`、`chat/socket/sync`、`upload`、`personalItems`、
`calendar`、`albums`、`pet`、`daily`、`cardGame`、`transcription`、`push`、`ai`、
`shared`、`stats`、`contracts`（实时协议权威定义）。

PostgreSQL 访问集中在 `db/`；migration 只追加不改写，当前 v37。公聊事件发到
`couple:<id>`，账号私有事件发到 `account:<id>`。

## 数据事实源

- PostgreSQL 是一切业务数据的唯一事实源；iOS SQLite 只是按账号隔离的设备缓存。
- Socket.IO 是低延迟通知，不是可靠通道；持久变更必须能靠 REST 或 Sync V2 补回。
- **新消息**的多设备补齐靠 Socket + `/api/bootstrap` + `/api/messages` 分页；
  Sync V2 对消息只同步撤回删除。
- 频道只有 `couple` 和 `ai`；未知频道拒绝或隔离，不能默认归入 `couple`。

## 可靠发送

```text
稳定 clientId → outbox 写 SQLite → UI 投影 pending
  → 媒体上传取得 uploadId → message:send
  → 服务端事务：幂等、绑定 upload、写消息、Sync 事件
  → ack/message:new 返回完整消息 → 本地持久化后删 outbox
```

不变量：

- `clientId` 在重试、重连、重启后不变；幂等作用域是会话 + 账号 + 设备。
- outbox 是待发消息唯一持久事实源；保存成功才调度发送；pending 不进正式表。
- ACK 返回的完整消息先写 SQLite 再替换 UI pending；已确认消息始终覆盖同
  `clientId` 的 pending。
- outbox 区分等待发送 / 正在发送 / 终止失败；重连只重放前者。
- ACK 丢失可重试，同一设备同一 `clientId` 必须返回同一条消息，不重复广播、
  不重复触发 AI 或推送。
- 媒体上传完成后重新取当前 socket；ACK 等待有独立硬超时，超限转明确失败。
- SQLite 写失败不能删 outbox 或伪装成功。
- 服务端不信任客户端媒体 URL，只接受归属正确且未被占用的 `uploadId`。
- 网络路径变化（Wi-Fi/蜂窝切换）废弃旧 socket，重连后自动重放 outbox。

## 历史窗口与分页

- 展示顺序固定 `(ts, id)`；分页、搜索都用 `(ts, id)` 复合游标，避免同毫秒漏重。
- 搜索/日期跳转后的内存时间线是目标附近的有界窗口；跨缺口翻页必须先取云端
  紧邻页，本机孤立缓存不能当下一页。
- 只有无方向游标的初始页计算 `total`，后续页返回 `null`。
- 完整历史始终有界加载。

## Sync V2

`GET /api/v2/sync` 返回 `protocolVersion: 2`、有序 `events`、`nextCursor`。
客户端整批校验并成功提交 SQLite 后才保存 cursor 并 ack；设备 ack 只单调增加。

**提交顺序**：sequence 分配顺序 ≠ 事务提交顺序。所有写同步事件的事务必须在
首次分配序号前取得同一个 transaction-level advisory lock（持有到 commit），
统一走 `appendSyncEvent`。rollback 可留空洞，客户端不要求序号连续。

**SQLite 提交**：批量 upsert 与 cursor 更新同一事务；任一失败整批回滚，
cursor/ack 不推进；磁盘满、锁、损坏必须当作失败传播，不能当空结果。

## 媒体

- 三个媒体入口都支持单段 HTTP Range（含 suffix Range，视频读 `moov` 必需）；
  非法 Range 返回 `416 + Content-Range: bytes */<size>`，不得退化为整段 200。
- 发送视频前在设备端导出 1080p MP4；历史高码率 MOV 流式播放失败时整段下载后
  本地播放，退出即清理。
- 图片上传时客户端附带 720px JPEG 缩略图（`thumbnailBase64` 字段）；气泡和
  网格先读缩略图，404 回退原图。
- 缓存身份 = host + path（`/media/up_*` 忽略 `sig/exp`），重新签发 URL 不会
  重复下载。图片盘上限 1 GiB、语音 256 MiB、文件预览 512 MiB，LRU 回收。
- 撤回、清历史、退出账号清理对应缓存；outbox 不随退出清空。
- `sig/exp` 等同短期 bearer token：请求日志去 query，边缘不记录 `/media/` 完整 URL。

## 权限边界

- `couple` 数据按 `couple_id` 共享；`ai` 私聊按 `conversation.owner_account_id`
  只对本人可见；提醒、设备、推荐状态、私有 Memory 按 `account_id` 隔离。
- 任何 AI 工具都不能读另一账号的私聊。
- `TOKEN_SECRET` 必须稳定，变更会使所有登录失效。
