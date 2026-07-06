# CoupleChat Backend Contract

Base URL 示例：`https://chat.huhuhu.top`

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

### `POST /api/me/push/bark`

鉴权：`Authorization: Bearer <token>`

请求：

```json
{ "barkKey": "xxxx" }
```

传 `null` 可清空。

### `POST /api/upload`

鉴权：`Authorization: Bearer <token>`

`multipart/form-data`，字段名不限，单文件。支持 jpeg/png/gif/webp/mp4/mov，最大 50MB。

响应：

```json
{
  "id": "up_xxx",
  "url": "https://example.com/uploads/up_xxx.jpg",
  "mimeType": "image/jpeg",
  "size": 12345,
  "type": "image"
}
```

## Socket.IO

连接：

```js
io("https://chat.huhuhu.top", {
  auth: { token }
})
```

服务端内部把 AI 私聊存成 `ai:<username>`，客户端只使用 `channel: "ai"`。
当前 AI 频道会返回本地兜底回复；后续接真实模型时保持同一事件契约。

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
  "clientId": "tmp-xxx"
}
```

#### `read:init`

```json
{ "channel": "couple", "state": { "xu": 1710000000000 } }
```

#### `read:update`

```json
{ "channel": "couple", "user": "xu", "ts": 1710000000000 }
```

#### `shared:init`

```json
{
  "pet:state": {
    "value": { "mood": "happy" },
    "updatedBy": "xu",
    "updatedAt": 1710000000000
  }
}
```

#### `shared:update`

```json
{
  "key": "pet:state",
  "value": { "mood": "happy" },
  "updatedBy": "xu",
  "updatedAt": 1710000000000
}
```

### 客户端事件

#### `message:send`

```json
{
  "channel": "couple",
  "type": "text",
  "text": "hi",
  "clientId": "tmp-xxx"
}
```

Ack：

```json
{ "ok": true, "id": "msg_xxx" }
```

媒体消息先走 `/api/upload`，再发送：

```json
{
  "channel": "couple",
  "type": "image",
  "url": "https://example.com/uploads/up_xxx.jpg",
  "clientId": "tmp-xxx"
}
```

#### `messages:fetch`

```json
{ "channel": "couple", "limit": 80 }
```

支持：

- `since`: 拉取指定时间戳之后的增量
- `before`: 上滑加载更早
- `around`: 跳转到某个时间附近

Ack：

```json
{ "ok": true, "list": [], "replace": true }
```

#### `messages:search`

```json
{ "channel": "couple", "query": "关键词", "limit": 50 }
```

#### `message:recall`

```json
{ "id": "msg_xxx" }
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
