# 已知问题与修复顺序

> 审查基线：2026-07-16，源码 `ee419a4ec26f54676543db8b0a392a6e7c798034`。这里只保留尚未解决或需要现场核验的问题；完成后应在同一提交更新状态。

## P0：代码已修复，合并前仍需对应环境验收

### SYNC-001：Sync V2 提交顺序保护待随版本发布

- **历史风险**：仅用 PostgreSQL sequence 分配 `server_seq` 时，较大序号可能先提交，客户端推进 cursor 后会永久跳过随后提交的较小序号。
- **代码现状**：`appendSyncEvent` 现在要求活跃的统一事务句柄，并在分配序号前取得同一 transaction-level advisory lock、持有到 commit/rollback。反序提交、回滚空洞、单事务多事件和 20 个独立 writer 并发轮询测试已通过。
- **剩余验收**：发布时必须先停旧 writer 再启新版本，禁止新旧实例重叠；精确提交的 CI 与上线后 Sync 健康仍需确认。旧 writer 不会取得新锁，混跑会重新打开原风险。

### IOS-001：SQLite 失败传播修复待 macOS CI/故障注入

- **历史风险**：部分 `sqlite3_step` 返回值未检查，批量写入可能按输入数量返回成功；云端消息没有落盘但设备认为已保存。
- **代码现状**：prepare/bind/step/finalize 和事务结果会传播失败；批量写任一失败则回滚；历史、bootstrap、分页、ACK、更新和撤回只有持久化成功后才更新权威内存或推进 cursor。回滚后无法确认 autocommit 时会失效连接。约束触发器已覆盖整批回滚与历史 cursor 不推进。
- **剩余验收**：当前 Windows 无法编译 Swift；需 macOS CI，并补只读数据库、磁盘满、finalize/rollback 失败注入。账号切换竞态另见 IOS-007。

### IOS-002：频道隔离修复待 macOS CI

- **历史风险**：客户端部分解码和实时路由曾把未知 channel 默认映射为 `couple`，未来私人事件可能错误显示在双方共享时间线。
- **代码现状**：字典/Codable、Socket、ACK、搜索、历史页、outbox 和 Sync V2 都严格接受 `couple|ai`；ACK 只有完全缺少 `message` 键时才允许旧协议回退，字段存在但无效或错频道会失败。Sync 整页所有 message 事件先校验，再应用并推进 cursor。
- **剩余验收**：新增契约测试仍需 macOS GitHub Actions 编译执行，并在两账号真机确认公聊/私聊不会串线。

### OPS-001：生产端口配置已统一，首次安装仍待实现

- **代码现状**：`.env.production.example`、Compose、Dockerfile、运行配置和健康检查的生产默认值已统一为 `127.0.0.1:3000`，非法端口会在启动时拒绝。
- **剩余风险**：全新主机首装与日常升级还没有独立的一键入口；bind mount UID/GID、`.env`、数据库、Nginx 和三层健康状态仍需人工 preflight。实现范围并入 OPS-004。

## P1：可靠性、安全与发布

### SYNC-002：时间戳分页不是稳定游标

同一毫秒多条消息时，只有 `ts` 的 `after/before/since` 可能重复、停滞或跳过。目标是使用 `(ts,id)` 复合游标，或统一使用服务端序号；迁移期保持旧参数兼容。

### SEC-001：认证入口需要完整的滥用防护

需要补齐可信代理边界、边缘与应用分层限流、退避、异步密码校验和压力测试。具体生产阈值与当前防护状态只记录在私有安全 runbook，不在公开仓库披露。

### SEC-002：密钥验证、用途和轮换不足

需要严格校验随机强度和布尔配置，按会话、内部调用和媒体用途拆分密钥，并支持 `kid`/双钥轮换；轮换前必须验证设备会话与历史媒体的兼容行为。

### SEC-003：媒体授权与日志脱敏需要升级

目标是短期 `exp+kid+scope` 或鉴权媒体接口，并在两层 Nginx/应用日志中脱敏查询参数。当前实现细节与上线顺序在修复前不写入公开文档。

### OPS-002：离机备份状态必须私下核验

公开仓库只定义 RPO/RTO 和验收要求，不记录供应商、容量或最近失败细节。每次发布前必须在私有 runbook 核对最近成功的加密离机副本与恢复演练；未核对时按不可用处理。

### OPS-003：应用回滚不等于数据库回滚

当前迁移只前进，服务启动又要求精确 schema。部署旧镜像在数据库已升级后可能直接失败，部分历史迁移还有删改数据。发布必须记录 schema 兼容区间；失败时只在已验证兼容的情况下回滚应用，否则使用经验证的数据库+uploads 一致备份恢复。

### OPS-004：部署链路尚未真正一键化

目标设计是单仓库产生仅含 `server/` 的固定 tag/SHA 发布包和 SHA-256，由美国主机部署入口完成锁、备份、候选构建、迁移、切换、三层健康检查和安全回退。该入口尚未实现，现阶段仍是人工流程。

### OPS-005：备份验证曾漏掉现行 Memory 表（代码已修复，待失败注入）

- **历史风险**：旧脚本列出已在 v7 重命名的 Memory 表名，且该表不是 required，因此可能静默漏过现行 Memory 数据。
- **代码现状**：`backup-table-policy.sh` 现在由备份和恢复脚本共同使用，按 schema 版本覆盖 v1–v31 migrations 中应存在的全部持久化表，包括现行 Memory、依赖、排除规则与运行状态。备份会拒绝缺少预期表或超出策略范围的 schema；恢复验证要求表清单完整、逐表比对计数，并确认 `message_server_seq_seq` 与 `sync_event_seq` 存在且不会低于已恢复数据。
- **剩余证据**：已在真实生产副本完成一次 schema v31 端到端恢复：51 张策略表、两条序列和媒体抽样通过。仍需在目标 Linux 做失败注入，并把结果纳入私有运维 runbook 后关闭本项。

### OPS-006：旧备份曾在新备份成功前被清理（代码已修复，待失败注入）

- **历史风险**：旧脚本先按保留期 prune，再创建新备份；新备份随后失败时可能已经删除 last-known-good。
- **代码现状**：现在只有新 daily 以及周日 weekly 完成本地哈希/归档校验并原子发布后才会 prune。轮转按不可变 `backup_id` 时间判龄，不受后来写入验证标记影响；未做恢复验证的新备份会至少保留一份旧成品，且最后一份 `quiesced + RESTORE-VERIFIED` 永远保留，`best_effort` 验证不能替代它。恢复脚本只有在随机临时库真实恢复、schema/全表计数/序列比对、媒体抽样和临时库删除全部成功后，才原子写入新版标记。
- **剩余证据**：本次真实生产发布已证明“先 quiesced 备份、恢复验证，再切换”的顺序可完成；目标 Linux 失败注入和加密离机副本确认仍未自动化。发布流程必须在私有 runbook 另行确认离机副本，且不得把 `best_effort` 备份作为 migration 门禁。

### DEV-001：生产只读检查尚未现场验收

脚本已移除内置主机和生产调试服务，只接受仓库外 SSH alias、专用 `READONLY_DATABASE_URL` 与 read-only transaction。剩余工作是在私有运维环境创建最小权限角色、配置 alias、核验目标身份并做拒绝写入测试；完成前不能用它证明生产状态。

### BUILD-001：重跑 attempt 与真实设备验收仍待完成

同 SHA reusable 质量门禁、固定 SHA 的 Action、带 commit/run/attempt/version/hash 的 metadata，以及按完整 commit 下载均已在 run `29487714361` 成功验证；下载器还接受标准 plist 的嵌套容器，并已原子发布到 `D:\Desktop\CoupleChat-IPA`。

**剩余验收**：尚未验证同一 run 的 rerun attempt 选择，也尚未在三台真实设备完成免费签名、安装和更新连续性验证。

### IOS-003：所有构建默认连接生产

Debug 与 Release 都使用 `https://hoo66.top`。需要明确 Development/Staging/Production 配置；在有隔离服务前，开发构建必须显示醒目标识并默认禁止破坏性测试。

### IOS-004：主线程读取大文件

附件、壁纸和部分媒体缓存路径在 UI/MainActor 上使用 `Data(contentsOf:)`，最大文件可达 50 MB。需要后台流式复制、分块读取和降采样解码，避免界面冻结和内存峰值。

### IOS-005：Sync 协议版本校验待 macOS CI

客户端已经显式解码并只接受 `protocolVersion == 2`；缺失或未来版本会在应用事件和推进 cursor 前失败，契约测试已加入。剩余工作是 macOS CI 执行，以及后续补用户可见的“客户端需要升级”提示。

### IOS-006：3D 模型失败路径修复待 macOS CI

资源缺失、GLTF 错误、资源为空和成功路径现在都会结束 spinner；失败时保留可访问的占位与提示，并已有容器状态测试。仍需 macOS CI 编译和一次真机损坏资源验证。

### IOS-007：账号切换仍有旧异步任务写入新会话的竞态

`MessageStore` 的部分非结构化任务、登出的异步 SQLite close 和下一账号 open 没有统一 session generation。快速登出/登录或切换账号时，旧 Socket/SQLite 任务可能晚到并影响新账号内存或数据库。需要为账号生命周期增加 generation/cancellation token，所有实时 handler 与持久化回调在提交结果前核对当前 session，并补快速切换压力测试。

### AI-001：生产 Trace 可能保存完整敏感内容

生产 AI 诊断需要默认关闭或强脱敏、明确权限、轮换和保留期；具体当前采集字段不在公开文档披露。上线验收必须证明私聊、prompt、工具结果和敏感 URL 不会被长期保留。

### UPLOAD-001：崩溃遗留临时文件会阻塞备份

`.uploading` 临时文件没有可靠的超时清理，而备份发现任何此类文件会拒绝继续。需要只删除超过安全年龄且无活跃 lease 的临时文件，并覆盖崩溃恢复测试。

## P2：维护性

- `MessageStore`、`ChatLocalDatabase`、原生消息 cell 等文件过大；先修 P0/P1，再按所有权小步拆分，禁止大爆炸重写。
- 一个 iOS target 使模块边界主要靠约定；先收紧协议和测试，再评估拆分 Swift Package/target。
- SwiftLint 关闭了若干复杂度规则，且 CI 已出现未来 Swift 并发隔离警告；按文件逐步收敛。
- Socket.IO 与 GLTFKit2 已固定精确版本，Actions 已固定完整 commit；但仓库尚无 `Package.resolved`，Homebrew 安装的 XcodeGen/SwiftLint 也未锁定瓶版本，发布链路仍不能完全重现历史依赖图。
- App 内授权文件已加入模型、GLTFKit2、Socket.IO Client Swift 与 Starscream 的主要许可文本；仍需核对 GLTFKit2 预编译 libktx/BasisU 等传递二进制的附加 notice。
