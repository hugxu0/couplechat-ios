# CoupleChat Backend Contract

Socket.IO 事件名和入站 payload 的运行时校验统一维护在 `src/contracts/realtime.ts`；本文件用于客户端开发和人工调试。

Base URL 示例：`https://hoo66.top`

## REST

### `GET /health`

返回服务健康状态。

```json
{ "ok": true, "ts": 1710000000000 }
```

### `GET /api/accounts`

公开账号列表，用于登录页选人。

```json
[
  { "username": "xu", "name": "小旭", "avatar": "🐶" },
  { "username": "si", "name": "小偲", "avatar": "🐰" }
]
```

### `POST /api/login`

请求：

```json
{ "username": "xu", "password": "..." }
```

响应：

```json
{ "token": "...", "username": "xu", "name": "小旭" }
```

### `GET /api/me`

鉴权：`Authorization: Bearer <token>`

核实 token 是否仍有效（Socket 返回 unauthorized 时 iOS 会二次确认）。

```json
{ "username": "xu", "name": "小旭" }
```

### `GET /api/bootstrap`

鉴权：`Authorization: Bearer <token>`

首次登录和恢复会话的有界快照。固定返回账号、每频道最近最多 40 条消息、已读状态和归一化后的共享状态。Socket 不再发送初始化快照。

### `GET /api/messages`

鉴权：`Authorization: Bearer <token>`

Query：`channel=couple|ai`，以及可选的 `since`、`after`、`before`、`around`、`limit`（最大 300）。响应：

```json
{ "ok": true, "list": [], "total": 389059 }
```

### `POST /api/me/push/bark`

鉴权：`Authorization: Bearer <token>`

请求：

```json
{ "barkKey": "xxxx" }
```

传 `null` 可清空。

### `GET /api/me/items`

鉴权：`Authorization: Bearer <token>`

当前账号的提醒/备忘。可选 query：
- `kind=reminder` 或 `kind=memo`
- `scope=personal`（默认）或 `scope=shared`

`scope=shared` 返回两人共享的提醒/备忘，不区分 owner。

```json
{
  "items": [
    {
      "id": "uuid",
      "owner": "xu",
      "kind": "memo",
      "scope": "personal",
      "title": "旅行计划",
      "bodyMarkdown": "## 周末\n- 订票",
      "dueAt": null,
      "isDone": false,
      "createdAt": 1710000000000,
      "updatedAt": 1710000000000
    }
  ]
}
```

### `POST /api/me/items`

鉴权：`Authorization: Bearer <token>`

```json
{
  "kind": "reminder",
  "scope": "shared",
  "title": "吃药",
  "bodyMarkdown": "**饭后**记得喝水",
  "dueAt": 1710000000000
}
```

`scope` 可选，默认 `"personal"`。`"shared"` 的 item 两人都能看到和编辑。

响应：`201 { "item": { ... } }`

### `PATCH /api/me/items/:id`

鉴权：`Authorization: Bearer <token>`

- `scope=personal`：仅 owner 可改
- `scope=shared`：两人均可改

```json
{ "title": "新标题", "bodyMarkdown": "- 支持 Markdown", "dueAt": null, "isDone": true }
```

### `DELETE /api/me/items/:id`

鉴权：`Authorization: Bearer <token>`

规则同 PATCH：`personal` 仅 owner；`shared` 两人均可删。

```json
{ "ok": true }
```

### `POST /api/upload?purpose=message|avatar|sticker`

鉴权：`Authorization: Bearer <token>`

`multipart/form-data`，字段名不限，单文件，最大 50MB。

客户端必须标明 `purpose=message|avatar|sticker`。只有 `purpose=message` 且超过 24 小时仍未绑定消息的文件会被定时清理，头像和贴纸不会误删。

支持 MIME：

| 类型 | MIME | 响应 `type` |
|------|------|-------------|
| 图片 | jpeg, png, gif, webp | `image` |
| 视频 | mp4, quicktime | `video` |
| 语音 | m4a, x-m4a, mp4, aac | `voice` |
| 文件 | pdf, zip, office, text, csv, json, octet-stream | `file` |

响应：

```json
{
  "id": "up_xxx",
  "url": "https://example.com/media/up_xxx?sig=<hmac>",
  "mimeType": "image/jpeg",
  "size": 12345,
  "type": "image"
}
```

新上传通过 HMAC 签名地址访问：`GET /media/<uploadId>?sig=<hmac>`。`/uploads/<filename>` 仅为数据库中已有的历史 URL 保留，且文件名只接受新后端 `up_<id>.<ext>` 或旧网页后端 `<13位毫秒时间戳>-<12位hex>.<ext>`；路由还必须命中 `uploads` 表，不能绕过新媒体的签名校验或访问任意磁盘路径。

### `GET /api/stats`

鉴权：`Authorization: Bearer <token>`

couple 频道近 10 天 + 近 12 月消息计数（按 username 分组）。**iOS 记录页已改成本地聚合，不再调用此接口**；接口仍保留供其他客户端使用。

### `GET /api/daily`

鉴权：`Authorization: Bearer <token>`

大橘日记 + 今日推荐。

```json
{
  "today": "2026-07-08",
  "yesterday": "2026-07-07",
  "diary": { "date": "2026-07-07", "bodyMarkdown": "..." },
  "recommend": { "date": "2026-07-08", "title": "...", "bodyMarkdown": "..." }
}
```

### `POST /api/daily/recommend`

鉴权：`Authorization: Bearer <token>`

强制重新生成今日推荐。

```json
{ "recommend": { "date": "2026-07-08", "title": "...", "bodyMarkdown": "..." } }
```

## Socket.IO

连接：

```js
io("https://hoo66.top", {
  auth: { token }
})
```

服务端内部把 AI 私聊存成 `ai:<username>`，客户端只使用 `channel: "ai"`。

- couple 频道：含 `@大橘` 召唤词时立即进入 Agent；否则在每 30 条主人文字的 Memory 批处理中同步生成冲突/搭话候选，达阈值后再由 Agent + MCP 复核并决定是否主动发言
- ai 私聊：每条文本/图片都回复
- 未配置 `AI_*` 时 ai 频道走本地兜底回复，couple 频道不插话

### 服务端主动事件

#### `presence`

```json
{ "online": ["xu"] }
```

#### `message:new`

```json
{
  "id": "msg_xxx",
  "sender": "xu",
  "senderName": "小旭",
  "kind": "user",
  "type": "text",
  "text": "hi",
  "channel": "couple",
  "ts": 1710000000000,
  "clientId": "tmp-xxx",
  "meta": null
}
```

`meta` 字段：仅 AI 消息的最后一条回复会携带，承载两类附加信息：

**确认卡**（AI 提议建提醒/备忘，主人确认后才写入）：

```json
{
  "confirm": {
    "status": "pending",
    "items": [
      { "action": { "type": "add_reminder", "title": "吃药", "time": "2026-07-09 08:00" }, "label": "提醒：吃药 · 2026-07-09 08:00" }
    ],
    "requesterName": "小旭",
    "requesterUsername": "xu"
  }
}
```

`status` 流转：`pending` → `confirmed`（含 `failed` 计数） / `cancelled`。

**搜索来源卡片**（AI 联网搜索返回的引用）：

```json
{
  "search": {
    "items": [
      { "url": "https://example.com/article", "title": "文章标题", "site_name": "Example", "summary": "..." }
    ],
    "ts": 1710000000000
  }
}
```

#### `message:update`

消息 meta 更新（确认/取消 action 后推回客户端）：

```json
{ "id": "msg_xxx", "meta": { "confirm": { "status": "confirmed", "failed": 0, ... } } }
```

#### `message:recalled`

消息被撤回后广播：

```json
{ "id": "msg_xxx", "channel": "couple", "by": "xu", "byName": "小旭" }
```

#### `ai:typing`

AI 私聊频道输入中指示（仅 `ai:<username>` room，payload 为 `boolean`）。

#### `read:update`

```json
{ "channel": "couple", "user": "xu", "ts": 1710000000000 }
```

常用 key（客户端约定，服务端只存 JSON blob）：

| key | 用途 |
|-----|------|
| `dates` | 在一起日期 |
| `anniversaries` | 纪念日 / 倒数日列表 |
| `screen_note` | 贴条（首页 overlay） |
| `chat_statuses` | 聊天首页状态 |
| `partner_recommend` | 今日推荐分享 |
| `pet:state` | 宠物状态（预留，iOS 尚未写入） |

#### `shared:update`

```json
{
  "key": "pet:state",
  "value": { "mood": "happy" },
  "updatedBy": "xu",
  "updatedAt": 1710000000000
}
```

#### `personalItem:changed`

当共享提醒/备忘被对方创建、修改或删除时，通过 `channel:couple` 广播。

```json
{
  "action": "created",
  "item": { "id": "uuid", "scope": "shared", ... }
}
```

`action` 为 `"created"` / `"updated"` / `"deleted"`（删除时 `item` 只含 `{ id }`）。

### 客户端事件

#### `message:send`

支持 `type`：`text` / `image` / `video` / `voice` / `sticker` / `file`

```json
{
  "channel": "couple",
  "type": "text",
  "text": "hi",
  "clientId": "tmp-xxx",
  "replyTo": "msg_yyy",
  "replyPreview": "被引用的摘要"
}
```

Ack：

```json
{ "ok": true, "id": "msg_xxx", "message": { "id": "msg_xxx", "clientId": "tmp-xxx", "ts": 1710000000000, "...": "完整消息" } }
```

客户端使用 ACK 中的完整 `message` 替换乐观气泡。

媒体消息先走 `/api/upload`，再发送：

```json
{
  "channel": "couple",
  "type": "image",
  "url": "https://example.com/media/up_xxx?sig=<hmac>",
  "uploadId": "up_xxx",
  "clientId": "tmp-xxx"
}
```

`image` / `video` / `voice` / `file` 必须携带 `uploadId`。服务端会校验该上传记录归当前用户所有、尚未绑定到其他消息，并以记录中的 URL 为准；`clientId` 可安全地用于重试。

#### `messages:search`

```json
{ "channel": "couple", "query": "关键词", "limit": 50 }
```

#### `message:recall`

```json
{ "id": "msg_xxx" }
```

#### `action:confirm`

用户在确认卡上点「确认」或「取消」：

```json
{ "messageId": "ai_xxx", "decision": "confirm" }
```

`decision` 为 `"confirm"` 或 `"cancel"`。服务端执行后通过 `message:update` 推回新 meta。

Ack：

```json
{ "ok": true }
```

#### `read`

```json
{ "channel": "couple", "ts": 1710000000000 }
```

#### `away`

```json
true
```

客户端进后台发 `true`，回前台发 `false`。

#### `health`

Ack：

```json
{ "ok": true, "ts": 1710000000000 }
```

用于 iOS 回前台判断 Socket 假活。

#### `shared:set`

```json
{ "key": "pet:state", "value": { "mood": "happy" } }
```
