# 接口契约

生产基地址：`https://hoo66.top`。除公开接口外，REST 请求使用：

```http
Authorization: Bearer <token>
```

错误通常返回 `{ "error": "code_or_message" }`。时间戳统一为 Unix 毫秒。

## REST

### 公开接口

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/health` | 数据库健康检查 |
| `GET` | `/api/accounts` | 未登录时返回 legacy 快捷账号；带 token 时返回当前情侣成员 |
| `POST` | `/api/login` | legacy 兼容登录；旧客户端可不传设备信息 |
| `POST` | `/api/v2/login` | 使用 `username/password/device` 登录并绑定当前设备 |
| `POST` | `/api/v2/register` | 使用 `username/password/name/device` 注册并绑定当前设备 |

登录成功返回 `token`、`username`、`name`、`deviceId` 和 `paired`。V2 的登录与注册都要求 device；字段与设备 Bark PUT 使用的安装信息一致。注册用户名为 3–24 位小写字母、数字或下划线，密码至少 8 位。

### 注册与配对

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/v2/couples` | 创建两人空间并生成 7 天邀请码 |
| `POST` | `/api/v2/couples/invites` | 重新生成邀请码，旧码立即失效 |
| `POST` | `/api/v2/couples/join` | 使用邀请码加入，最多两名 active member |
| `GET` | `/api/v2/me/couple` | 查询当前账号是否已配对 |

创建/加入操作按账号事务串行，避免同一账号并发进入两段关系。新注册情侣的大橘当前使用“无历史模式”：可正常回复当前消息和识图，但在 conversation/Memory 工具完成全租户迁移前不会读取历史。

### 当前用户与同步

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me` | 核验 token，返回当前账号 |
| `GET` | `/api/bootstrap` | 最近消息、账号、已读和共享状态快照 |
| `GET` | `/api/messages` | 消息分页或增量读取 |
| `POST` | `/api/me/push/bark` | 设置或清除当前账号 Bark key |

旧 `/api/me/push/bark` 为 V1 兼容接口。新客户端使用设备级接口：

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/me/devices` | 查看当前账号的有效设备与 Bark 状态 |
| `PUT` | `/api/v2/me/devices/current/push/bark` | 注册/更新当前安装并设置本设备 Bark key |
| `DELETE` | `/api/v2/me/devices/:id` | 撤销一台设备并停用它的推送 endpoint |

PUT body 包含 `installationId`、`platform`、`deviceName`、`appVersion`、`buildNumber`、`locale`、`timezone` 和可为 null 的 `barkKey`。安装 ID 由 iOS Keychain 持久化；同一账号的 iPhone/iPad 可各自保留独立 Bark key。

`GET /api/messages` 参数：

| 参数 | 说明 |
|---|---|
| `channel` | 必填，`couple` 或 `ai` |
| `since` | 返回该时间之后的消息 |
| `after` | 向更新方向分页 |
| `before` | 向更早方向分页 |
| `around` | 获取某个时间附近的消息 |
| `limit` | `1...300`，默认 `80` |

响应为 `{ ok, list, total }`。同一请求不要同时组合多个方向参数。

### 上传与媒体

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/upload?purpose=message|avatar|sticker` | multipart 单文件上传，最大 50 MB |
| `GET` | `/media/:id?sig=...` | 当前签名媒体地址 |
| `GET` | `/uploads/:filename` | 已有消息的兼容媒体地址 |

上传成功返回 `id`、`url`、`mimeType`、`size` 和 `type`。发送媒体消息时必须使用返回的 `id` 作为 `uploadId`。

### 提醒与备忘

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me/items?kind=&scope=` | 查询可见事项 |
| `POST` | `/api/me/items` | 创建事项 |
| `PATCH` | `/api/me/items/:id` | 修改事项 |
| `DELETE` | `/api/me/items/:id` | 删除事项 |

`kind` 为 `reminder` 或 `memo`，`scope` 为 `personal` 或 `shared`。主要字段为 `title`、`bodyMarkdown`、`dueAt` 和 `isDone`。

到期通知由服务端 Bark 调度器负责：`shared` 提醒发送给当前两位账号的全部有效设备 endpoint，`personal` 只发送给 `owner` 的全部有效设备。投递按提醒、到期时间和收件账号持久化记账，服务重启会补扫最近 7 天，成功不重复、失败继续重试。iOS 不再额外安排本地到期通知；旧账号单 Bark key 仍作为兼容 fallback。

### 每日内容

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/daily` | 最近日记和今日推荐 |
| `POST` | `/api/daily/recommend` | 重新生成今日推荐 |

### Memory 控制中心

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me/memory?scope=&layer=&q=&limit=&cursor=` | 查询当前用户可见的 Memory、统计和下一页 cursor |
| `GET` | `/api/me/memory/:id/evidence` | 查询一条 Memory 的原文证据 |
| `PATCH` | `/api/me/memory/:id` | 手动纠正内容或重要程度 |
| `DELETE` | `/api/me/memory/:id` | 彻底删除 Memory 及其证据关联 |
| `POST` | `/api/me/memory/refresh` | 立即整理共同聊天或当前用户私聊 |

`scope` 为 `all/shared/private`；`layer` 为 `fact/event/plan/state/relationship/insight`；`q` 搜索正文、分类和主体。列表默认只返回 active Memory，响应含 `nextCursor/hasMore`。

共同 Memory 对双方可见；`ai:<username>` 私聊 Memory 只对对应账号可见。`PATCH` body 为 `{ content, importance?, baseVersion }`，importance 范围 `1...5`；版本冲突返回 409 和权威 `item`，客户端会载入它。删除会记录 exclusion，不能被相同证据自动重新生成。`POST refresh` body 为 `{ scope: "shared" | "private" }`。

### Sync V2

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/sync?cursor=&limit=` | 按 account/couple 拉取持久化变更与 tombstone |
| `POST` | `/api/v2/sync/ack` | 保存当前设备已应用的最大 cursor |

iOS 在前台约每 10 秒补拉一次，并在 Socket 重连、启动和回前台时立即补拉。撤回删除、Memory、提醒、相册、日历、转写和宠物变更都进入事件日志；普通消息仍由 Socket + 消息分页负责。

### 语音转写

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/messages/:messageId/transcript` | 查询转写状态与修正版 |
| `POST` | `/api/v2/messages/:messageId/transcript/retry` | 补建或重试新旧语音的后台任务 |
| `PATCH` | `/api/v2/messages/:messageId/transcript` | `{ text, baseVersion? }` 纠正文字 |

状态为 `pending/processing/completed/failed/unavailable`。发送语音不等待转写；搜索使用修正版。provider 未配置时 retry 仍返回 200 和权威 `unavailable` transcript；iOS 也兼容旧服务端的同结构 503。撤回会级联删除音频关联、转写和 job。后台 provider 由 `TRANSCRIPTION_*` 环境变量配置。

### 共同相册与那年今日

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET/POST` | `/api/v2/albums?cursor=&limit=` | cursor 分页列出/创建当前情侣相册 |
| `PATCH/DELETE` | `/api/v2/albums/:albumId` | 带 `baseVersion` 修改/删除相册 |
| `GET` | `/api/v2/albums/:albumId/items` | cursor 分页读取相册项目 |
| `POST` | `/api/v2/albums/:albumId/items/from-message` | 把本情侣聊天媒体加入相册 |
| `DELETE` | `/api/v2/albums/:albumId/items/:itemId` | 从相册移除，不删除原聊天媒体 |
| `PATCH` | `/api/v2/media-assets/:assetId/note` | 写双方可见注脚 |
| `GET` | `/api/v2/media/on-this-day?timezone=&date=` | 查询往年同月同日的已收藏媒体 |

相册列表响应为 `{ albums, nextCursor, hasMore }` 并返回稳定 `coverURL`。同一媒体重复加入同一本相册会幂等为空，不产生重复项目。

### 共享日历

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/calendar/events?view=month&month=&timezone=` | 月视图读取 shared + 当前账号 private 日程 |
| `GET` | `/api/v2/calendar/events?view=agenda&cursor=&limit=` | Agenda cursor 分页 |
| `POST` | `/api/v2/calendar/events` | 新建 `shared/private` 日程 |
| `PATCH` | `/api/v2/calendar/events/:id` | 带 `baseVersion` 修改 |
| `POST` | `/api/v2/calendar/events/:id/complete` | 完成或恢复日程 |
| `DELETE` | `/api/v2/calendar/events/:id` | 带 `baseVersion` 删除 |

日程保存 `timezone/allDay/startAt/endAt`，全天范围按设备当前日历的本地午夜与下一自然日归一化。修改冲突返回 409 和权威 `event`。Bark 到期提醒仍由“提醒”域承担：shared 发双方，personal 只发创建者；日历本身当前不自动推送。

### 大橘共同养成

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/pet` | 聚合名字、小窝、今日题目、藏品、足迹和最近互动 |
| `POST` | `/api/v2/pet/today/responses` | 幂等提交当前用户回应 |
| `POST` | `/api/v2/pet/interactions` | 摸摸、碰爪、逗猫棒 |
| `PATCH` | `/api/v2/pet/scene` | 带 `baseVersion` 布置藏品 |
| `PATCH` | `/api/v2/pet/name` | 带 `baseVersion` 改名 |

两位成员都回应后只结算一次藏品并生成足迹；没有饥饿、生病、连续打卡或掉亲密度等惩罚机制。

## Socket.IO

连接时在 auth 中传 token：

```javascript
io("https://hoo66.top", { auth: { token } })
```

### 客户端发送

| 事件 | payload | ack/效果 |
|---|---|---|
| `health` | 无 | `{ ok, ts }` |
| `away` | `boolean` | 更新在线状态 |
| `message:send` | 消息请求 | `{ ok, message }` 或错误 |
| `message:recall` | `{ id }` | 撤回结果 |
| `messages:search` | `{ channel, query, limit? }` | 搜索结果 |
| `read` | `{ channel, ts }` | 广播已读状态 |
| `shared:set` | `{ key, value }` | 写共享 JSON 对象 |
| `action:confirm` | `{ messageId, decision }` | 确认或取消 AI 操作 |

`message:send` 主要字段：

```json
{
  "channel": "couple",
  "type": "text",
  "text": "你好",
  "clientId": "device-generated-id",
  "replyTo": null,
  "replyPreview": null,
  "uploadId": null,
  "attachments": null,
  "meta": null
}
```

- `type`：`text/image/video/sticker/voice/file`。
- 图片、视频、语音和文件必须引用 `uploadId`；贴纸可使用已有贴纸 URL。
- 服务端契约支持 Live Photo `attachments`，每个 asset 至少有 `photo`，可带 `pairedVideo`；当前 iOS 选择器仍只发送静态照片，完整配对资源列入 V2 媒体域。
- `clientId` 应始终提供，用于重试幂等。

### 服务端推送

| 事件 | 用途 |
|---|---|
| `message:new` | 新消息或发送方最终确认 |
| `message:recalled` | 消息已撤回 |
| `message:update` | AI 确认卡等元数据更新 |
| `read:update` | 已读状态变化 |
| `presence` | 在线账号列表 |
| `shared:update` | 共享状态变化 |
| `personalItem:changed` | 共享提醒/备忘变化 |
| `ai:typing` | AI 私聊输入状态 |
| `ai:replying` | AI 私聊回复状态 |
| `ai:activity` | AI 请求 accepted/generating/finished/failed 阶段 |

## 协议修改流程

1. 修改 `server/src/contracts/realtime.ts` 的事件和 Zod schema。
2. 修改 `Sources/Core/Networking/SocketContract.swift` 的事件和请求结构。
3. 更新服务端处理与 iOS 调用点。
4. 补充 `SocketContractTests` 或后端冒烟断言。
5. 更新本文档。
