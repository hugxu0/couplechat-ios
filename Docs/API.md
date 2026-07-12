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
| `GET` | `/api/accounts` | 登录页账号列表 |
| `POST` | `/api/login` | 使用 `username/password` 登录 |

登录成功返回 `token`、`username` 和 `name`。

### 当前用户与同步

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me` | 核验 token，返回当前账号 |
| `GET` | `/api/bootstrap` | 最近消息、账号、已读和共享状态快照 |
| `GET` | `/api/messages` | 消息分页或增量读取 |
| `POST` | `/api/me/push/bark` | 设置或清除当前账号 Bark key |

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

### 每日内容

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/daily` | 最近日记和今日推荐 |
| `POST` | `/api/daily/recommend` | 重新生成今日推荐 |

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
- Live Photo 使用 `attachments`，每个 asset 至少有 `photo`，可带 `pairedVideo`。
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
