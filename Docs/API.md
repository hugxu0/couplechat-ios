# 接口契约

生产基地址：`https://hoo66.top`。除公开接口外，REST 请求使用：

```http
Authorization: Bearer <token>
```

错误通常返回 `{ "error": "code_or_message" }`。时间戳统一为 Unix 毫秒。

## REST

### 服务探针与公开资源

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/live` | 只检查 Node.js 进程存活，不访问数据库 |
| `GET` | `/ready` | 数据库就绪检查；不可用时返回 503 |
| `GET` | `/health` | 与 `/ready` 相同的兼容健康检查 |
| `GET` | `/assets/couplechat-icon.png` | Bark 通知默认图标，缓存一周 |

### 登录与账号

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/accounts` | 未登录时返回 `xu/si` 快捷账号；带 token 时返回当前共享空间成员 |
| `POST` | `/api/v2/login` | 使用 `username/password/device` 登录并绑定当前设备 |

登录成功返回 `token`、`username`、`name` 和 `deviceId`。token 必须绑定当前设备和有效 session；没有设备/session 绑定的旧 token 不再接受。`device` 必须包含 `installationId/platform`，并可带 `deviceName/appVersion/buildNumber/locale/timezone`；字段与设备 Bark PUT 使用的安装信息一致。服务端只认证 `xu/si`；注册、情侣空间创建/加入、邀请码和配对状态接口均不存在。

### 当前用户与同步

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me` | 核验 token，返回当前账号 |
| `GET` | `/api/bootstrap` | 最近消息、账号、已读和共享状态快照 |
| `GET` | `/api/messages` | 消息分页或增量读取 |
| `GET` | `/api/messages/:id` | 按 ID 读取当前共享空间内的一条消息，用于引用定位 |
| `GET` | `/api/v2/chat/stats` | 按上海时区返回近 35 天及全部月份的双方聊天计数 |
| `GET` | `/api/v2/me/devices` | 查看当前账号的有效设备与 Bark 状态 |
| `PUT` | `/api/v2/me/devices/current/push/bark` | 绑定/更新当前安装并设置本设备 Bark key |
| `POST` | `/api/v2/me/devices/current/push/bark/test` | 向当前设备发送一条 Bark 连通性测试 |
| `DELETE` | `/api/v2/me/devices/:id` | 撤销一台设备并停用它的推送 endpoint |

PUT body 包含 `installationId`、`platform`、`deviceName`、`appVersion`、`buildNumber`、`locale`、`timezone` 和可为 null 的 `barkKey`。安装 ID 由 iOS Keychain 持久化；同一账号的 iPhone/iPad 可各自保留独立 Bark key。

`GET /api/messages` 参数：

| 参数 | 说明 |
|---|---|
| `channel` | 必填，`couple` 或 `ai` |
| `since` | 返回该时间之后的消息 |
| `after` | 向更新方向分页（含起点） |
| `before` | 向更早方向分页 |
| `around` | 获取某个时间附近的消息（含同毫秒行） |
| `beforeId` / `afterId` / `sinceId` | 可选，与对应时间戳组成 `(ts,id)` 复合游标；缺省时仅 `ts`（兼容旧客户端） |
| `limit` | `1...300`，默认 `80` |

响应为 `{ ok, list, total }`。`after` 与 `before` 可以组合；`around`、`since` 与方向分页不要组合。推荐始终带上锚点消息 `id`，避免同毫秒漏重。

`GET /api/messages/:id` 必须带 `channel=couple|ai`，响应为 `{ ok, message }`。服务端先按当前账号解析共享空间，再以共享空间和消息 ID 联合查询；找不到或不属于当前共享空间时统一返回 `404 not_found`。客户端只在点击引用预览且原消息不在内存或本地数据库时使用该接口，取回后继续加载消息附近的有界窗口。

### 大橘日记

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/ai/diaries?limit=` | 列表（按 dayKey 倒序） |
| `GET` | `/api/v2/ai/diaries/:dayKey` | 单日日记 |
| `POST` | `/api/v2/ai/diaries/ensure` | 确保昨日或指定 `dayKey` 日记（body 可选 `{ dayKey, force }`） |

只读 couple 材料；无信号日返回 `404 empty_or_unavailable`。

### 上传与媒体

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/upload?purpose=message|avatar|sticker|album` | multipart 单文件上传，最大 50 MB |
| `GET` | `/media/:id?sig=...&exp=...` | 签名媒体地址；新签发含 `exp`（默认 TTL 24h，可用 `MEDIA_URL_TTL_SECONDS`）；无 `exp` 的历史签名仍兼容 |
| `GET` | `/uploads/:filename` | 已有消息的兼容媒体地址 |

上传成功返回 `id`、`url`、`mimeType`、`size` 和 `type`。发送媒体消息时必须使用返回的 `id` 作为 `uploadId`。

两个媒体读取入口均支持单段 HTTP Range，并返回 `Accept-Ranges: bytes`、`206` 和 `Content-Range`。必须正确支持 `bytes=start-end`、`bytes=start-` 与 `bytes=-suffixLength`；视频播放器会使用 suffix Range 读取文件尾部元数据，不能把它退化成整文件响应。

### 提醒与备忘

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me/items?kind=&scope=` | 查询可见事项 |
| `POST` | `/api/me/items` | 创建事项 |
| `PATCH` | `/api/me/items/:id` | 修改事项 |
| `DELETE` | `/api/me/items/:id` | 删除事项 |

`kind` 为 `reminder` 或 `memo`，`scope` 为 `personal` 或 `shared`。主要字段为 `title`、`bodyMarkdown`、`dueAt` 和 `isDone`。

到期通知由服务端 Bark 调度器负责：`shared` 提醒发送给当前两位账号的全部有效设备 endpoint，`personal` 只发送给 `owner` 的全部有效设备。投递按提醒、到期时间和收件账号持久化记账，服务重启会补扫最近 7 天，成功不重复、失败继续重试。iOS 不再额外安排本地到期通知；旧账号单 Bark key 仍作为兼容 fallback。

### Memory 控制中心

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/me/memory?scope=&layer=&perspective=&kind=&status=&subject=&q=&limit=&cursor=` | 查询当前用户可见的 Memory、统计和下一页 cursor |
| `GET` | `/api/me/memory/:id/sources` | 查询关系/理解卡引用的基础记忆 |
| `PATCH` | `/api/me/memory/:id` | 手动纠正内容或重要程度 |
| `DELETE` | `/api/me/memory/:id` | 彻底删除 Memory |
| `POST` | `/api/me/memory/refresh` | 立即整理共同聊天或当前用户私聊 |

`scope` 为 `all/shared/private`；`layer` 为 `fact/event/plan/state/relationship/insight`；`perspective` 为 `people/daju`；`kind` 为 `standard/instruction/observation`；`status` 为 `active/all`；`subject` 为 `xu/si/both`；`q` 搜索正文、分类和主体。`limit` 范围 `1...200`、默认 `100`。列表默认只返回 active Memory，并按时间键 `COALESCE(occurred_at, valid_from, created_at)` 倒序，再以 `id` 倒序稳定排序；响应含 `nextCursor/hasMore`。`cursor` 是服务端不透明值，分页游标携带该时间键和 id。未指定 `perspective` 时，Agent 的普通人物检索只读取 `people`；客户端选择“大橘”时会显式请求 `daju`，并按指令或观察分类。

共同 Memory 对双方可见；`ai:<username>` 私聊 Memory 只对对应账号可见。`PATCH` body 为 `{ content, importance?, baseVersion? }`，importance 范围 `1...5`；提供旧 `baseVersion` 时返回 409 和权威 `item`，客户端会载入它。删除会按卡片 key 记录 exclusion，避免后台再次自动生成；主人之后明确重新下达同主题指令时可以恢复。`POST refresh` body 为 `{ scope: "shared" | "private" }`；服务端最多同步等待 20 秒，响应中的 `pending` 表示整理仍在后台进行，完成后的 Memory 变更通过 Sync V2 触发客户端重新读取。

### 今日推荐

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/recommendations/today` | 获取双方相同的大橘推荐、对方最新推荐和未读状态 |
| `POST` | `/api/v2/recommendations/refresh` | 重新生成一条大橘推荐 |
| `POST` | `/api/v2/recommendations` | 用 `{ content }` 给对方发送纯文字推荐 |
| `GET` | `/api/v2/recommendations/unread-count` | 获取对方推荐未读数 |
| `GET` | `/api/v2/recommendations/history?cursor=&limit=` | 分页读取大橘和双方推荐历史 |
| `POST` | `/api/v2/recommendations/:id/read` | 收下推荐并将此前待收推荐标为已读 |
| `DELETE` | `/api/v2/recommendations/:id` | 只从当前账号的历史中隐藏该推荐 |

作息日按北京时间 06:00 切换。`today` 返回 `cycleDate/daju/partner?/latestUnread?/unreadCount`；后台启动时立即检查，之后每 15 分钟幂等补建，读取 `today` 时也会按需生成。大橘推荐返回自由文本 `category` 和纯文字 `content`，分类不使用固定枚举；生成目标是一个具体的作品、食物、地点或体验，而不是待办、提醒或日程建议。大橘主要以昨天双方可见的 `event` 经历卡作为口味线索，并用共同 `state/plan/fact` 补充；不会读取私密记忆，也不直接使用 `relationship/insight`。生成会排除最近 12 条大橘推荐；同一明确对象或高文本相似结果会有限重试，模型不可用或输出不合法时也会轮换并跳过近期内置推荐。刷新后的推荐仍对双方完全相同。

双方互荐正文长度为 `1...500`。`read` 只接受当前账号收到的成员推荐，并把时间不晚于目标的未读推荐一并标记已读；`DELETE` 只写当前账号的隐藏状态，不删除双方共享的推荐记录。历史 `limit` 范围 `1...100`，默认 `30`。

### 增量同步

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/sync?cursor=&limit=` | 按 account/couple 拉取持久化变更与 tombstone |
| `POST` | `/api/v2/sync/ack` | 保存当前设备已应用的最大 cursor |

`GET` 的 `cursor` 默认 `0`，`limit` 范围 `1...500`、默认 `200`；响应为 `{ protocolVersion: 2, events, nextCursor, hasMore }`。`ack` body 为 `{ cursor }`，必须使用带 `deviceId` 的设备会话，服务端只单调推进设备 ack。

iOS 在前台约每 10 秒补拉一次，并在 Socket 重连、启动和回前台时立即补拉。撤回删除、Memory、推荐、提醒、相册、日历、转写和宠物变更都进入事件日志；普通消息仍由 Socket + 消息分页负责。

### 语音转写

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/messages/:messageId/transcript` | 查询转写状态与文字 |
| `POST` | `/api/v2/messages/:messageId/transcript/retry` | 补建或重试新旧语音的后台任务 |

状态为 `pending/processing/completed/failed/unavailable`。发送语音不等待转写；已完成文字可被搜索。服务端不提供人工纠正转写。provider 未配置时 retry 返回 200 和权威 `unavailable` transcript。撤回会级联删除音频关联、转写和 job。后台 provider 由 `TRANSCRIPTION_*` 环境变量配置。

### 共同相册

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET/POST` | `/api/v2/albums?cursor=&limit=` | cursor 分页列出/创建当前情侣相册 |
| `PATCH/DELETE` | `/api/v2/albums/:albumId` | 带 `baseVersion` 修改/删除相册 |
| `GET` | `/api/v2/albums/:albumId/items` | cursor 分页读取相册项目 |
| `POST` | `/api/v2/albums/:albumId/items/from-message` | 把本情侣聊天媒体加入相册 |
| `POST` | `/api/v2/albums/:albumId/items/from-upload` | 把本机原图/视频加入指定相册动态 |
| `DELETE` | `/api/v2/albums/:albumId/items/:itemId` | 从相册移除，不删除原聊天媒体 |
| `PATCH` | `/api/v2/media-assets/:assetId/note` | 写双方可见注脚 |

相册分页 `limit` 范围 `1...100`、默认 `30`。列表响应为 `{ albums, nextCursor, hasMore }`，每本相册同时返回稳定 `coverURL` 和最多三项 `previewItems`。创建 body 为 `{ title, summary? }`；修改封面、标题或摘要以及删除相册均使用 `baseVersion`。直接上传 body 为 `{ uploadId, takenAt?, postId? }`；同一次发表复用同一 `postId`，因此不同拍摄时间的多张照片/视频仍属于一条可整体编辑或删除的时间线动态。聊天消息入册以 `message:<messageId>` 作为动态分组。v25 之前没有 `postId` 的旧项目继续按拍摄分钟和文案兼容分组。同一媒体重复加入同一本相册会幂等为空。

相册图片/视频预览复用聊天媒体浏览器：全屏、左右只浏览当前动态的媒体，上下拖动超过阈值缩回对应缩略图；文案编辑入口位于时间线正文右侧，不放进图片浏览器。

### 共享日历

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/calendar/events?view=month&month=&timezone=` | 月视图读取 shared + 当前账号 private 日程 |
| `GET` | `/api/v2/calendar/events?view=agenda&cursor=&limit=` | Agenda cursor 分页 |
| `POST` | `/api/v2/calendar/events` | 新建 `shared/private` 日程 |
| `PATCH` | `/api/v2/calendar/events/:id` | 带 `baseVersion` 修改 |
| `POST` | `/api/v2/calendar/events/:id/complete` | 完成或恢复日程 |
| `DELETE` | `/api/v2/calendar/events/:id` | 带 `baseVersion` 删除 |

创建 body 包含 `scope/title/notes/startAt/endAt/timezone/allDay`；修改、完成/恢复和删除都必须提供 `baseVersion`。月视图必须提供合法 IANA `timezone`，`limit` 最大 500；Agenda `limit` 最大 100、默认 30。日程保存 `timezone/allDay/startAt/endAt`，全天范围按设备当前日历的本地午夜与下一自然日归一化。修改冲突返回 409 和权威 `event`。Bark 到期提醒仍由“提醒”域承担：shared 发双方，personal 只发创建者；日历本身当前不自动推送。

### 大橘共同养成

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/v2/pet` | 获取等级、经验、四项状态、最近互动和冷却 |
| `POST` | `/api/v2/pet/interactions` | 喂食、洗澡、玩耍、摸摸或睡觉；带版本与幂等键 |

两位成员操作同一只服务端宠物；状态会随时间自然衰减，互动结果、版本与冷却同步到双方设备。当前没有每日题目、藏品、场景布置、改名、连续打卡或生病机制。

互动 body 为 `{ kind, idempotencyKey, baseVersion }`，`kind` 取 `feed/bathe/play/stroke/sleep`。版本或幂等冲突返回 409；冷却未结束返回 429，并带 `availableAt` 与权威 `pet`。

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
| `message:send` | 消息请求 | `{ ok, id, message, requestId }` 或 `{ ok: false, error }` |
| `message:recall` | `{ id }` | 撤回结果 |
| `messages:search` | `{ channel, query, limit?, cursor? }` | `{ ok, list, nextCursor, hasMore }` |
| `read` | `{ channel, ts }` | 广播已读状态 |
| `shared:set` | `{ key, value }` | 写共享 JSON 对象 |
| `action:confirm` | `{ messageId, decision }` | 确认或取消 AI 操作 |

`message:send` 成功确认固定返回完整的当前消息；iOS 直接用 `message` 替换本地 pending，不支持只返回 `id` 的旧确认格式。引用消息只使用扁平字段 `replyTo/replyPreview`，不接受或返回旧的嵌套 `reply`。

`messages:search` 按 `(ts DESC, id DESC)` 稳定排序；`limit` 范围为 `1...100`、默认 `50`。`cursor` 为上一页返回的 `{ ts, id }`，客户端仅在 `hasMore=true` 且 `nextCursor` 非空时继续加载。第一页和游标页都不能混入不连续的本地近期片段；离线时客户端可单独展示本机已有结果，但不声称仍有云端下一页。

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
- `text` 最长 8,000 字符；`replyPreview` 最长 500 字符。
- 图片、视频、语音和文件必须引用 `uploadId`；贴纸可使用已有贴纸 URL。
- 服务端契约支持最多 9 个 Live Photo asset（最多 18 个 attachment part）；每个 asset 必须有 `photo`，可带一个 `pairedVideo`，同一上传不能重复引用。当前 iOS 选择器仍只发送静态照片。
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

## 内部与调试接口

- `POST /api/ai-mcp` 是服务端 Agent 的无会话 Streamable HTTP MCP 入口，只接受当前单轮生成的 `X-CoupleChat-AI-Run` token；它不是 App 或第三方可调用的公开 API。`GET/DELETE` 固定返回 405。
- `/ai-debug` 与 `/api/ai-debug/*` 仅在非生产环境、loopback 请求下可见。Trace、Memory 与消息清理接口用于隔离数据库调试，不属于生产客户端契约；需要身份的读取/清理接口仍使用 Bearer token。

## 协议修改流程

1. 修改 `server/src/contracts/realtime.ts` 的事件和 Zod schema。
2. 修改 `Sources/Platform/Networking/SocketContract.swift` 的事件和请求结构。
3. 更新服务端处理与 iOS 调用点。
4. 补充静态契约检查或后端冒烟断言。
5. 更新本文档。
