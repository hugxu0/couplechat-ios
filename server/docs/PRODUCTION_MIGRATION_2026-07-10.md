# 生产数据迁移记录（2026-07-10）

## 范围

- 源端：美国 RackNerd，旧网页后端 `/root/chat`，SQLite + `data/uploads` + `data/ai_docs`
- 目标端：日本 RFCHost，新原生后端 `/opt/couplechat-ios/server`，PostgreSQL
- 源端一致性快照截止：`2026-07-10 09:56:05 CST`
- 目标端生产服务：`https://hoo66.top`

## 最终数据

| 数据 | 数量 |
|---|---:|
| messages | 389,461 |
| read_receipts | 2 |
| shared_items | 11 |
| personal_items | 12（10 reminders + 2 memos） |
| uploads | 347 / 190,652,967 bytes |
| ai_facts | 109（109 个 embedding） |
| ai_episodes | 4,374（4,374 个 embedding） |
| ai_docs | 1,270（启动后台任务后正常继续增加） |

消息时间范围：`1733059587000...1783647407026`。目标端缺失媒体文件为 0，`alice/bob` 用户名和旧私聊频道残留为 0。

## 转换规则

- `alice → xu`，`bob → si`
- `ai:alice → ai:xu`，`ai:bob → ai:si`
- `memory_facts → ai_facts`
- `knowledge_cards → ai_episodes`
- `shared.reminders/memos → personal_items`
- 旧人物卡、关系卡、短期记忆、每日详细日记、推荐、心情和 session summary → `ai_docs`
- 全部 `daily_cache` 另存为 `legacy-cache:*`，避免信息丢失
- 旧文件生成受控 `uploads` 索引；运行时兼容严格的 `13位时间戳-12位hex.ext` 文件名
- 旧 `chunk_embeddings` 不进入新运行库；完整 SQLite 备份仍保留

## 备份与回滚

美国源端切换备份：

```text
/root/codex-backups/chat-cutover-20260710-095638
```

包含完整 `chat.db`、精简迁移 SQLite、uploads/AI docs 压缩包、代码配置和 SHA-256。

日本迁移前备份：

```text
/root/codex-backups/couplechat-migration-20260710-094945
```

日本迁移后备份：

```text
/root/codex-backups/couplechat-post-migration-20260710-113553
```

恢复前先停止 PM2。数据库使用 `pg_restore --clean --if-exists` 恢复迁移前 dump；运行目录使用同目录 tar 包恢复。所有备份已有 SHA-256 校验清单。

## 验证结果

- `npm test` 通过
- `npm run smoke:legacy-import` 全量通过
- PostgreSQL `VACUUM ANALYZE` 完成
- 生产登录 + `/api/me` 通过（未输出 Token）
- `/health`：数据库 `ok`
- Socket.IO Engine.IO 握手：HTTP 200/open packet
- 真实旧媒体：HTTP 200，447,718 bytes
- PM2、PostgreSQL、Nginx：active/online
- 美国旧站恢复 HTTP 200

注意：美国旧站在快照后恢复运行，两端从此独立写入。新功能和日常聊天应以日本新后端为准。
