# 持续开发基础约定

本项目优先保证聊天、离线缓存和服务端数据的一致性；新功能应在既有边界内扩展，而不是直接跨层读写状态。

## 1. 实时协议

- 服务端 Socket.IO 事件名、Zod 校验和推导类型统一维护在 `server/src/contracts/realtime.ts`。
- iOS 事件名和可编码请求体统一维护在 `Sources/Core/SocketContract.swift`。
- 新增或修改 Socket 字段时，必须同时更新两份契约、`server/docs/API.md` 和至少一条冒烟测试断言。
- 客户端请求使用 `Codable` 结构体编码；不要在功能页面里散落事件字符串或手写字段字典。

## 2. 异步加载

- 只要需要网络结果，API 就必须是 `async`，不能“发请求后立即返回本地空值”。
- 消息列表先读本地 SQLite，再按需从 Socket 补齐；网络返回后统一通过 `MessageStore.upsertBatch` 写入内存与本地库。
- UIKit/SwiftUI 只负责触发和渲染，历史加载、分页、重试逻辑留在 `MessageStore`。

## 3. 本地 SQLite

- 每个账号使用独立数据库文件，路径为 `Application Support/ChatCache/<username>.sqlite`。
- `ChatLocalDatabase` 使用递归锁和 SQLite FULLMUTEX，允许主线程与后台任务安全串行访问同一连接。
- 使用 WAL、5 秒 busy timeout，并通过 `PRAGMA user_version` 管理本地 schema。
- 修改本地表结构时只追加迁移：提高 `schemaVersion`，为每个版本写幂等迁移，并保留旧迁移。
- 待发消息写入 `pending_outbound_messages`；媒体原文件写入 `Application Support/ChatOutboxMedia/<username>` 并排除 iCloud 备份。只有收到 ACK 或带相同 `clientId` 的正式消息后才清理。
- outbox 重放必须复用原 `clientId` 并串行发送，不能通过“删除失败气泡再创建新消息”的方式重试。

## 4. HTTP 依赖

- `AuthStore`、`MessageStore`、`SharedStore` 都通过 `HTTPClient` 请求网络，默认实现是 `URLSessionHTTPClient`。
- 大媒体使用 `HTTPClient.upload(for:fromFile:)` 从文件上传，禁止重新拼出整份内存 multipart body。
- 新媒体只使用服务端返回的 HMAC 签名 `/media/<id>?sig=...`；不要根据本地文件名自行拼 `/uploads` URL。历史 `/uploads` 仅用于旧数据兼容。
- `ChatStore` 构造时可注入同一个 `HTTPClient`；单元测试应使用固定响应的 stub，不连接真实服务端。

## 5. PostgreSQL

- 服务端迁移定义在 `server/src/db/index.ts` 的 `schemaMigrations`，每条迁移都有不可复用的版本号。
- 启动时在事务内执行未应用迁移，并写入 `schema_migrations`；不要再在业务代码中临时 `ALTER TABLE`。
- 发布涉及数据库的改动前先执行 `pg_dump`，并在预发布/本地跑 `npm test`。
- 从旧网页后端恢复生产数据使用 `server/scripts/import-legacy-production.ts`，必须先停写、备份并跑 `npm run smoke:legacy-import`；不要临时手写跨 schema SQL。

## 6. 验证门槛

```bash
cd server
npm test                     # TypeScript + 内嵌 PostgreSQL 冒烟
npm run healthcheck -- https://hoo66.top
```

iOS 当前在 Windows 开发，因此每次改动 Swift、`project.yml` 或资源后，都应运行 GitHub Actions 的 **Build iOS IPA (unsigned)**。涉及聊天时还需真机验收登录、历史加载、发送/重发、离线缓存和前后台重连。

## 7. AI 应答边界

- AI 入口不得静默丢请求：上游空响应、异常、总超时和配置缺失都必须有用户可见的兜底。
- 同一频道串行调用模型；积压过多时只合并尚未开始的请求为最新一条，不能让超时旧任务晚到后乱序写入。
- 当前请求在提示词中只能出现一次；证据优先级是当前请求、紧邻上文、明确召回记忆、摘要、人物卡。
- 人物卡和长期记忆只提供背景，不能覆盖用户刚表达的事实，也不能被当成心理诊断。
- 任务、联网、识图等能力规则按意图注入；可执行任务还需本地确定性意图兜底，不能完全依赖 LLM 分类。

## 8. 新功能检查表

1. 明确领域模型与本地/服务端数据归属。
2. 定义 REST 或 Socket 契约，并补服务端输入校验。
3. 补离线、重连、超时和重复请求策略。
4. 为关键路径补单元或冒烟测试。
5. 更新 API、交接和功能文档。
