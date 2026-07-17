# 数据同步与可靠性设计

## 目标与事实源

PostgreSQL 是消息、已读、共享状态和业务实体的唯一事实源。iOS SQLite 是账号隔离的设备缓存；Socket.IO 是低延迟通知通道，不能作为唯一可靠通道。任何实时事件都必须能通过 REST/Sync V2 补回。

频道只有：

- `couple`：双方共享；
- `ai`：当前账号私有，服务端映射到该账号拥有的 conversation。

未知频道必须拒绝或隔离，绝不能默认进入 `couple`。

## 客户端发送

```text
生成稳定 clientId
  → pending outbound outbox 记录写入 SQLite
  → UI 从 outbox/发送动作投影内存 pending message
  → 媒体先流式上传并取得 uploadId
  → message:send
  → 服务端事务做 clientId 幂等、绑定 upload、写消息和同步事件
  → ack/message:new 用服务端消息替换 pending
  → 删除 outbox
```

关键不变量：

- `clientId` 在重试、重连和重启后保持不变；
- outbox 是待发消息的唯一持久事实源，`pending/failed/tmp` 不写入正式 messages 表；重启后从 outbox 重新投影 UI pending；
- outbox 保存成功后才允许调度网络发送；客户端只有确认本地事务成功后才推进 cursor 或清理 outbox；
- 服务端不信任客户端媒体 URL，只接受已存在且归属正确的 `uploadId`；
- ack 丢失允许重试，服务端必须返回同一个完整消息而不是创建第二条消息；客户端不再根据旧式 `id` 确认自行拼装服务端消息。

## 客户端接收

1. Keychain 恢复 token，同时打开账号专属 SQLite。
2. `/api/bootstrap` 提供账号、最近消息、已读和共享状态快照；离线时允许先展示有界缓存。
3. 连接 Socket.IO，实时事件先做契约校验、去重，再写 SQLite 和时间线。
4. 启动、重连、回前台和前台周期检查通过 `/api/v2/sync` 拉取持久化变更。
5. 完整历史通过 `/api/messages` 有界分页，不把全部记录一次载入内存。

同一消息可能从 bootstrap、REST 分页、Sync V2、Socket 或 outbox ack 到达。去重身份使用服务端 `id`，乐观替换使用 `clientId`；展示顺序不能只依赖到达顺序。

## Sync V2

请求：`GET /api/v2/sync?cursor=<server_seq>&limit=<1...500>`。

响应必须显式包含 `protocolVersion`、有序 `events`、`nextCursor` 和 `hasMore`。设备 ack 只单调增加；客户端只有在整批事件完成契约校验并成功提交 SQLite 后才保存新 cursor 和发送 ack。

### 提交顺序保护

单独依赖 PostgreSQL sequence 不足以证明提交顺序：sequence 值的分配顺序不等于事务提交顺序，较大序号可能先可见。当前实现因此在统一事件写入边界 `appendSyncEvent` 中加入同一个 transaction-level advisory lock：

所有创建同步事件的事务必须在第一次分配序号前获得同一个 `pg_advisory_xact_lock`：

1. lock 在事务内获取并持有到 commit/rollback；
2. 获取 lock 后才调用 `nextval` 和写事件；
3. 一个事务的多个事件连续分配；
4. rollback 可以留下序号空洞，客户端不要求连续，只要求已提交事件严格按序可见；
5. `DatabaseTransaction` 只有在统一事务作用域活跃时才有效，运行时代码禁止伪造事务句柄或绕开统一事件写入函数。

这会串行化“同步事件编号到提交”的短临界区，适合当前单主库和低并发双用户产品。反序提交、回滚空洞、单事务多事件和 20 个独立连接并发轮询已经进入 PostgreSQL 测试。部署该修复时必须先停止所有旧 writer，再启动新版本；旧版本不会取得这把锁，新旧 writer 重叠仍会破坏保证。

长期若吞吐或多服务实例增加，迁移为业务事务内 transactional outbox，再由单一 dispatcher 分配发布序号。

## 历史分页

当前 `/api/messages` 支持：

- `before`：向更早；
- `after`：向更新；
- `after + before`：读取半开区间 `[after,before)`，用于有界核对；
- `since`：增量兼容参数；
- `around`：目标时间附近。

当前只用毫秒 `ts` 不是稳定游标，同一毫秒多条消息可能重复或跳过。目标游标是 `(ts,id)`，排序与边界都使用同一组合；迁移期保留旧参数但客户端优先使用复合 cursor。

## SQLite 提交规则

- 每个 `sqlite3_prepare/bind/step/finalize` 错误都必须转换为可观察失败；
- 批量 upsert 与 cursor 更新必须处于同一 transaction；
- 任一消息失败则整批 rollback，返回真实写入结果；
- 磁盘满、数据库锁、约束冲突和损坏不能被当作空结果；
- UI/MainActor 不直接访问 SQLite 或同步读取大文件。

当前客户端代码已把批量写入、撤回删除和历史分页改为真实检查返回值：历史页任一行格式/频道错误或任一 SQLite 写入失败时，整页不被接受且 Sync cursor/ack 不推进；撤回只有数据库事务成功后才清理权威内存。回滚后若 SQLite 连接不能确认已回到 autocommit，连接会被立即失效，避免继续使用状态未知的事务。约束回滚已有自动测试；磁盘满、只读文件系统、finalize/rollback 故障注入仍需在 macOS/iOS 测试环境补齐。

## 协议兼容

- 当前 Sync protocol 为 `2`；客户端必须建模并只接受明确支持的版本范围。
- 这个私人项目只维护同一发布线上的当前客户端与当前服务端；REST/Socket 字段删除必须两端、测试和文档在同一提交完成，不保留长期旧格式兼容层。
- Socket 事件名以 `server/src/contracts/realtime.ts` 和 `Sources/Platform/Networking/SocketContract.swift` 为两端代码契约；文档是人类入口，测试负责防漂移。

## 必须覆盖的测试

- 两事务先分配后反序提交；
- 分配序号后 rollback；
- 单事务多事件；
- 至少 20 个并发事务与客户端轮询；
- Socket 断开期间写入，重连由 Sync V2 全量补回；
- 同一事件经 Socket 与 Sync 重复到达；
- SQLite 中途失败时 cursor 不推进；
- 同毫秒多消息分页；
- 未知 channel 和未知 protocolVersion 被安全拒绝；
- 同一 `clientId` 在超时、重试和重启后只产生一条服务端消息。
