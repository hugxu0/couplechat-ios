# 悄悄话 V2 技术架构

> 决策日期：2026-07-13
> 迁移原则：扩表 → 回填 → 双写 → 切流 → 最后收缩
> 兼容要求：不修改任何已发布的 v1–v10 migration；v11–v22 仍是本次未发布候选，可在首次生产迁移前修正；`xu / si` 不重新注册、不重新配对、数据无损

截至 2026-07-13，身份、设备会话、conversation ownership、Sync V2、Memory ownership、转写、相册、日历和宠物的可运行基线已落地。下文中 preference 云同步、通用 notification intent、短期 access/refresh token、`sync:available` 唤醒和完整统一媒体库仍是后续目标，不应误读成当前生产能力。

## 1. 为什么先做公共底座

V2 要支持其他情侣、同账号多设备、相册、日历和服务端宠物。如果继续使用全局 `couple` channel、账号级单 Bark key 和无确认的 Socket 状态覆盖，新功能完成后仍会因所有权和同步模型变化而重写。

这里的情侣隔离首先是功能正确性，而不是安全优先级：服务端必须知道一张照片、一个计划和一只宠物究竟属于哪对情侣。

最低前置包括：

1. 稳定的 `account / couple / member / device / conversation` ID。
2. 每个实体有明确 owner scope。
3. HTTP cursor sync、幂等 mutation、版本号和删除 tombstone。
4. 相册、壁纸、贴纸和语音共用 `media_assets`。
5. Bark 使用设备级 endpoint 和持久化投递箱。

## 2. 身份与所有权

```text
Account
  ├─ Device ── Session ── Bark Endpoint
  └─ CoupleMember ── Couple
                       ├─ Couple Conversation
                       ├─ Calendar
                       ├─ Album
                       ├─ Pet
                       └─ Couple Memory

Account
  ├─ Private AI Conversation
  ├─ Private Reminder
  └─ Account Preferences / Stickers / Favorites
```

| 数据 | 所有者 |
|---|---|
| 账号资料、主题、AI 私聊、私人提醒、贴纸、收藏 | `account_id` |
| 情侣聊天、共享提醒、日历、相册、宠物、共同 Memory | `couple_id` |
| 情侣壁纸、对方备注等关系内偏好 | `member_id` |
| Bark、客户端版本、在线设备 | `device_id` |
| 消息 | `conversation_id`，由 conversation 决定 account/couple owner |

当前限定一个账号只有一段 active 情侣关系；表结构保留未来历史关系扩展能力。

## 3. 核心表

### 3.1 Account、Couple、Member、Invite

现有 `accounts.username` 在兼容期保留为主键，新增不可变 `accounts.id`、`status`、`version`。

```text
couples
  id, name, status, created_by_account_id, created_at, updated_at, version

couple_members
  id, couple_id, account_id, role, state, joined_at, left_at, updated_at
  UNIQUE(couple_id, account_id)
  UNIQUE(account_id) WHERE state = 'active'

couple_invites
  id, couple_id, code_hash, created_by_member_id,
  expires_at, used_at, used_by_account_id, revoked_at
```

一对情侣最多两名 active member，由创建/加入事务校验。邀请码只存 hash。

### 3.2 Device 与 Session

```text
devices
  id, account_id, installation_id, platform, device_name,
  app_version, build_number, protocol_version, locale, timezone,
  last_seen_at, revoked_at, created_at
  UNIQUE(account_id, installation_id)

auth_sessions
  id, account_id, device_id, refresh_token_hash, token_version,
  created_at, last_seen_at, expires_at, revoked_at

device_push_endpoints
  id, device_id, provider, secret_value, endpoint_fingerprint,
  enabled, failure_count, last_success_at, disabled_at, created_at, updated_at
  UNIQUE(device_id, provider)
```

客户端首次启动生成 `installation_id` 并存入 Keychain。当前 HMAC access token 绑定 `session_id/device_id/token_version`，默认 90 天且可由设备撤销；refresh token 轮换尚未开放。相同 Bark key 可以属于同账号多台设备，投递时按 endpoint fingerprint 去重。

### 3.3 Conversation、Message 与严格已读

```text
conversations
  id, kind(couple/ai), couple_id, owner_account_id, created_at, archived_at
```

- couple conversation 只有 `couple_id`。
- AI conversation 只有 `owner_account_id`。
- 每个 active couple 一个情侣会话，每个 account 一个私人 AI 会话。

`messages` 追加：

```text
conversation_id, sender_account_id, origin_device_id, server_seq
```

幂等索引：

```text
UNIQUE(conversation_id, sender_account_id, origin_device_id, client_id)
WHERE client_id IS NOT NULL
```

严格已读不用时间戳猜测：

```text
conversation_reads
  conversation_id, account_id, last_read_message_id,
  last_read_server_seq, updated_by_device_id, updated_at
  PRIMARY KEY(conversation_id, account_id)
```

客户端只有同时满足以下条件才上报：scene active、目标聊天页可见、消息 cell 已展示。服务端只允许 `last_read_server_seq` 单调增加。

### 3.4 现有业务表所有权

`personal_items` 追加 `owner_account_id / couple_id / created_by_account_id / version / deleted_at`：

- personal 只设 `owner_account_id`。
- shared 只设 `couple_id`；`created_by_account_id` 仅表达创建者。

`uploads` 追加 `created_by_account_id / couple_id / access_scope`。

AI Memory、cursor、runtime state、daily content 逐步从全局字符串 `couple` 或 `ai:xu` 迁移到 `conversation_id`、`couple_id` 或 `account_id`。不能继续扩展全局 `ai_docs` 与字符串 key。

## 4. Sync V2

Socket 负责低延迟唤醒，HTTP cursor sync 是可靠性来源。

### 4.1 事务事件日志

```text
sync_version_seq

sync_events
  seq, couple_id, account_id, entity_type, entity_id,
  operation(upsert/delete), entity_version, payload_json,
  actor_account_id, actor_device_id, mutation_id, created_at
```

每条 event 必须恰好属于一个 `couple_id` 或一个 `account_id`，并建立 `(couple_id, seq)`、`(account_id, seq)` 索引。

每次业务修改在同一 PostgreSQL 事务中：

1. 取得全局 `seq`。
2. 修改实体并写入 `version=seq`。
3. 插入包含完整实体快照或 tombstone 的 sync event。
4. 客户端在启动、Socket 重连、回前台和前台约 10 秒轮询时拉取事件。`sync:available` 唤醒仍待实现。

### 4.2 幂等和冲突

```text
client_mutations
  account_id, device_id, mutation_id, response_json, event_seq, created_at
  PRIMARY KEY(account_id, device_id, mutation_id)
```

所有写请求带 `X-Device-ID` 与 `Idempotency-Key`；更新带 `baseVersion` 或 `If-Match`。

- 简单偏好采用服务端时间 LWW。
- 日历、宠物布置等结构化实体版本不一致时返回 `409`，客户端刷新并明确展示冲突。
- 删除必须写 tombstone；离线设备恢复后才能确定性清理本地实体。

### 4.3 API

当前候选已经实现数字 `server_seq` cursor 的 `GET /api/v2/sync` 与 ack；启动快照仍使用兼容 `/api/bootstrap`，尚无 retention/`410 cursor_expired`。下列是完成态目标：

```text
GET  /api/v2/bootstrap
GET  /api/v2/sync?cursor=<opaque>&limit=500
POST /api/v2/sync/ack
```

目标中的 `/api/v2/bootstrap` 在 repeatable-read 事务中取得一致快照和 event watermark；只返回最近消息窗口，旧消息继续独立分页。

cursor 对客户端不透明。服务端当前可编码 `{v:2,seq}`；事件被清理导致 cursor 过期时返回 `410 cursor_expired`，客户端重新 bootstrap。

### 4.4 Socket

当前候选已切换 `couple:<id>`、`account:<id>` 房间并按 socket 维护 presence，但尚未实现 `device:<id>` 房间、`sync:available` 唤醒和带 `visibleConversationId` 的新版 presence。下列是完成态目标：

握手携带 access token、device ID、protocol version 和 last cursor。房间改为：

```text
couple:{coupleId}
account:{accountId}
device:{deviceId}
```

可靠事件只通知“有新同步内容”：

```text
sync:available { throughCursor, changedTypes }
presence:set   { scene, visibleConversationId }
presence:changed
```

typing 等临时交互继续直接走 Socket，但不进入 sync log。即使 Socket 完全断线，HTTP cursor 仍可恢复全部持久数据。

## 5. 多设备设置、贴纸、收藏和壁纸

```text
account_preferences(account_id, key, value_json, version, updated_by_device_id, updated_at, deleted_at)
member_preferences(member_id, key, value_json, version, updated_by_device_id, updated_at, deleted_at)
couple_settings(couple_id, key, value_json, version, updated_by_account_id, updated_by_device_id, updated_at, deleted_at)
```

- account preference：主题、深浅模式、AI 私聊壁纸。
- member preference：情侣聊天壁纸、当前关系内的对方备注。
- couple setting：简单共享标量；日历、相册、宠物必须用独立表。

```text
sticker_groups(id, account_id, name, sort_rank, is_default, version, deleted_at, ...)
stickers(id, account_id, group_id, media_asset_id, is_favorite, sort_rank, version, deleted_at, ...)
message_favorites(account_id, message_id, created_at, version, deleted_at)
```

收藏只引用 canonical message，不复制文字或签名 URL。撤回 message tombstone 会同步清理收藏关系。

## 6. 统一媒体资产

相册、消息附件、Live Photo、贴纸、自定义壁纸、语音与宠物场景素材统一引用 `media_assets`，不各自保存 URL。

```text
media_assets
  id, couple_id, owner_account_id, created_by_account_id,
  kind, mime_type, checksum, byte_size, width, height, duration,
  captured_at, timezone, storage_key, thumbnail_key,
  live_photo_pair_id, processing_status, version, deleted_at, created_at
```

所有外部 URL 临时签名；数据库保存稳定 storage key。上传先建 asset，再流式传输，支持大小预检、后台队列、进度、取消、重试和去重。

完整撤回由一个服务端事务/工作流产生级联 tombstone：

```text
message
├─ attachments / media assets（无其他合法引用时）
├─ thumbnails / derived files
├─ transcript / search index
├─ reply preview / favorite
├─ album item / on-this-day entry
└─ Memory evidence / orphan Memory
```

客户端不能自行拼接部分删除结果。

## 7. Bark 多设备投递

```text
notification_intents
  id, couple_id, source_type, source_id, kind, scheduled_at, dedupe_key, created_at

notification_recipients
  intent_id, account_id, reason

notification_deliveries
  id, intent_id, account_id, device_id, push_endpoint_id,
  status, attempt_count, next_attempt_at, sent_at, last_error
  UNIQUE(intent_id, push_endpoint_id)
```

收件人规则固定为：

- 共享提醒：情侣双方所有启用 Bark 的 active devices，包括创建者。
- 私人提醒：owner 的所有启用设备。
- 情侣消息：对方所有启用设备。
- AI 私聊：owner 的所有启用设备。
- 消息只跳过“当前这台设备正在前台查看该 conversation”的 endpoint；另一台设备在线不能抑制整个账号的通知。
- 定时提醒不因在线状态抑制。

调度器扫描数据库中到期且未完成的 intent；delivery 唯一约束保证服务重启后不漏发、不重复。

设备 API：

```text
PUT    /api/v2/me/devices/current/push/bark
GET    /api/v2/me/devices
DELETE /api/v2/me/devices/:deviceId
```

## 8. 新功能的服务端域

### 相册与那年今日

```text
albums, album_items, media_notes, media_sources, on_this_day_hides
```

相册只引用 media asset，不依赖聊天 URL；那年今日是可重建索引/查询，不复制原始内容。

### 日历与计划

```text
calendar_events, event_participants, event_reminders, task_lists, tasks
```

保存 `timezone` 与 all-day 语义；不继续扩展 `personal_items` 或纪念日 JSON。

### 语音转写

```text
message_transcripts
  message_id, couple_id, status, language, text, segments_json,
  provider, model, edited_text, version, error_code
```

后台 job 完成后写 sync event；Memory 与搜索使用 `edited_text ?? text`。

### 大橘宠物

```text
pets, pet_actions, pet_scene_items, pet_inventory,
pet_prompt_instances, pet_prompt_responses, pet_unlocks, pet_moments
```

服务端是权威状态源；动作使用幂等 key，奖励结算在事务内完成。宠物使用 append-only action ledger，不把整只宠物覆盖写入一个 shared JSON。

## 9. `xu / si` 无感迁移

固定 legacy ID：

```text
xu account/member       acc_legacy_xu / mem_legacy_xu
si account/member       acc_legacy_si / mem_legacy_si
couple                  cpl_legacy_xusi
couple conversation     conv_legacy_couple
xu / si AI conversation conv_legacy_ai_xu / conv_legacy_ai_si
```

回填：

- `messages.channel='couple'` → `conv_legacy_couple`
- `messages.channel='ai:xu|si'` → 对应 private AI conversation
- `shared_items` → legacy couple settings
- personal items → 对应 owner account；shared items → legacy couple
- uploads.owner → created_by account
- Memory `couple / ai:xu / ai:si` → 对应 conversation
- 旧 `accounts.bark_key` → synthetic legacy device + endpoint

真实 V2 设备提交相同 Bark key 时，依据 fingerprint 转移 endpoint 并停用 synthetic device，防止重复推送。

主题、贴纸、收藏和壁纸目前仍只在本地；账号级首次导入与“服务端已有 preference 时不被后升级设备覆盖”是后续目标，当前候选尚未实现。

## 10. Additive migration 路线

| 版本 | 内容 | 核心验收 |
|---|---|---|
| v11 | `hard_delete_recalled_messages` | 清理旧撤回占位、引用预览和孤立 Memory |
| v12 | `durable_reminder_bark_delivery` | V1 Bark 重启不漏发/重复，失败可重试 |
| v13 | `identity_v2_expand` | 旧账号、密码、消息数量不变 |
| v14 | `devices_sessions_push` | 手机和平板独立登录/撤销；旧 Bark 继续工作 |
| v15 | `reminder_delivery_per_endpoint` | 同账号多设备独立去重与失败重试 |
| v16 | `conversations_and_ownership` | 新测试情侣无法查询 legacy couple 数据 |
| v17 | `sync_v2_core` | 事务事件、设备 cursor 与撤回 tombstone |
| v18 | `tenant_memory_and_settings` | Memory/简单共享设置按 account/couple 隔离 |
| v19 | `voice_transcription` | 转写状态、job lease、纠正与撤回级联 |
| v20 | `shared_albums` | 媒体资产、相册、项目和共同注脚 |
| v21 | `shared_calendar` | 共享/私人日历、参与者和版本冲突 |
| v22 | `shared_pet` | 宠物、题目、双人回应、藏品、场景和足迹 |

最终 contract migration 只在所有真实设备升级 V2 后执行，包括删除旧全局 clientId 索引、停止 legacy 双写和将新 ownership 字段设为 NOT NULL。

## 11. 向后兼容发布顺序

1. 只部署 schema expansion，不改变接口行为。
2. 部署同时支持 v1/v2 的服务器；v1 请求在服务端解析为 legacy account/couple。
3. legacy couple 的 v1 mutation 双写新 canonical 表与旧投影。
4. 发布 iOS V2，注册 device、使用 cursor sync、导入本地账号数据。
5. 确认两位用户的实际 iPhone/iPad 均为 protocol v2。
6. 再开放其他情侣注册配对。
7. `/api/accounts` 兼容期只返回 `xu/si`；V2 登录不再依赖公开账号列表。
8. 旧客户端退出后停止双写，最后执行 contract migration。

## 12. 轻量备份

- 每日一次 `pg_dump` 自定义格式；保留 7 个日备份和 4 个周备份。
- 媒体目录按 storage key 增量同步到第二位置；数据库备份记录对应媒体 watermark。
- 本机备份目录以 root-only 权限保存；若复制到异机或对象存储，再用单一离线密钥加密，不建设复杂 KMS。
- 每次部署前额外生成快照。
- 提供一个恢复脚本：新建临时数据库 → restore → migrate → 校验表计数与抽样 media checksum。
- 每月至少自动执行一次临时恢复验证；只有“能恢复”的文件才算备份。

## 13. 必须自动化的验收矩阵

- legacy `xu/si` 数据无损，新测试 couple 无法读取其消息、Memory、presence、提醒和媒体。
- 同一账号 iPhone/iPad 同时在线；撤销一个 session 不影响另一个。
- A 离线、B 修改任意实体，A 仅靠 cursor 补齐；mutation 重试十次只产生一次结果。
- recall/delete 在离线设备恢复后清掉所有派生数据。
- 已读只在消息真正展示后单调推进；启动时间或收到 Socket 不能伪造已读。
- 共享提醒双方全部设备收到，私人提醒只有 owner；服务端在到期前后重启仍不漏不重。
- iPad 横屏、Split View、Stage Manager、键盘、指针；iPhone 大字体、VoiceOver、Reduce Motion。
- 备份可在空环境恢复并通过健康检查与数据抽样。
