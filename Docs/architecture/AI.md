# 大橘 AI 系统

> 当前生产只服务 `xu/si`。两位用户使用完整 Agent、MCP、历史检索与自动 Memory，数据通过 conversation/account/couple ownership 约束。

## 回答链路

```text
`xu/si` 主人消息写入 PostgreSQL
  ├─ 增量整理 Memory
  ├─ 更新窗口外对话摘要
  └─ 需要回复时
       → ReplyQueue
       → OpenAI Agents SDK
       → MCP 工具（按需）
       → 1～3 条回复 / 确认卡 / 来源卡片
       → 消息入库并广播
```

`couple` 频道仅在出现 `AI_TRIGGER_ALIASES` 时直接回答；个人 `ai` 频道每条文字或图片都进入回答链路。每个频道串行执行，超时会释放队列并提供可见反馈，积压时保留最新请求。

## 代码位置

| 路径 | 职责 |
|---|---|
| `server/src/ai/index.ts` | 入口分流、消息广播和后台触发 |
| `agent/runtime.ts` | Agent instructions、模型和 MCP 连接 |
| `agent/replyQueue.ts` | 队列、超时、多条回复和确认卡 |
| `mcp/` | 工具服务器、单轮身份、预算和工具实现 |
| `memory/store.ts` | Memory 生命周期、检索、证据和向量 |
| `memory/extractor.ts` | 新消息增量整理与强校验 |
| `memory/maintenance.ts` | 过期状态、计划和无效证据维护 |
| `conversation/` | 最近消息、上下文摘要和原文搜索 |
| `background/` | 大橘日记和周期维护任务 |
| `debug/` | 本机 Trace 与 Memory 调试页 |

## Agent 输入

完整 Agent 每轮初始输入包含北京时间、说话人、频道权限、窗口外摘要、最近 14 条聊天和当前问题。工具结果由 Agent 在同一轮继续处理，不重复塞进初始输入。

窗口外摘要保存在 `ai_runtime_state`，它是可重建的上下文，不是长期事实，也不能替代主人原文证据。

## Memory

| 层 | 内容 | 生命周期 |
|---|---|---|
| `fact` | 身份、偏好、习惯、健康等稳定事实 | 同 key 更新 |
| `event` | 已发生的重要事情 | 追加、证据幂等 |
| `plan` | 未来安排和承诺 | 可完成、取消或过期 |
| `state` | 情绪、健康、忙碌等短期状态 | 默认带有效期 |
| `relationship` | 关系身份、共同约定和边界 | 同 key 更新 |
| `insight` | 多条消息支持的谨慎观察 | 高证据门槛、弱化表达 |

当前候选运行表：

- `ai_memory`：结构化内容、状态、范围、置信度、时间和 embedding；
- `ai_memory_evidence`：关联主人原始消息与摘录；
- `ai_memory_cursor`：每个 conversation 已整理到的 `(cursor_ts, cursor_id)`，保留 legacy channel 兼容键；
- `ai_memory_exclusions`：用户忘掉后阻止同一证据重新生成；
- `ai_runtime_state`：摘要和每日内容等可重建状态。

整理器按游标读取主人文字消息，累积到固定批次后调用 task 模型，校验变更类型、主体、目标记忆和证据，再在事务中写入并推进游标。无效 JSON、缺失证据或写入失败都不能推进游标。

关键规则：

- AI 自己的回答不能成为事实证据；
- 主人撤回原文后，对应证据失效，无剩余证据的记忆退出 active；
- 洞察至少需要三条本批新消息支持；
- 公聊只读取双方公开数据，私聊可额外读取当前用户私聊；
- 不确定时明确表示无法确认，不能把搜索候选写成确定事实。

### App 内控制中心

生产登录用户可通过 `我的 → 大橘与记忆` 管理自己可见的 Memory：

- 共同范围按 `couple_id` 隔离；个人范围按 `account_id` 隔离，legacy scope 字符串只保留兼容，不能跨账号读取私聊。
- 支持按范围、层级和自然语言筛选，查看原始证据摘录。
- 手动纠正正文时记录修改者和时间、清空旧 embedding，后续维护任务会重新生成向量。
- “忘掉”物理删除 Memory 行并写 exclusion；`ai_memory_evidence` 通过外键级联删除，原聊天消息保留。
- 可以分别立即整理共同聊天和当前账号的 AI 私聊。
- 列表已支持 cursor 分页、版本冲突和 Sync V2 跨设备刷新。

尚未完成的是来源证据一键跳回聊天和本地离线缓存；runtime/tool 以 `conversation_id/couple_id/account_id` 为边界。

## MCP 工具

- 分层 Memory 检索和证据读取
- 原始聊天搜索及相邻上下文
- 当前用户可见提醒/备忘查询
- 需要确认的事项操作草案
- 当前或最近图片理解
- 联网搜索和来源收集

工具不提供任意 SQL、任意数据库 CRUD 或跨用户私聊读取。

## 配置

配置值保存在环境变量中，不写入仓库：

```env
AI_BASE_URL=
AI_API_KEY=
AI_MODEL=

AI_CHAT_BASE_URL=
AI_CHAT_API_KEY=
AI_CHAT_MODEL=

AI_TASK_BASE_URL=
AI_TASK_API_KEY=
AI_TASK_MODEL=

AI_VISION_BASE_URL=
AI_VISION_API_KEY=
AI_VISION_MODEL=

AI_MCP_URL=http://127.0.0.1:8080/api/ai-mcp
AI_TRIGGER_ALIASES=@大橘

EMBEDDING_VOYAGE_PROVIDER=
EMBEDDING_VOYAGE_BASE_URL=
EMBEDDING_VOYAGE_API_KEYS=
EMBEDDING_MODEL=voyage-4
EMBEDDING_DIM=1024
```

`AI_CHAT_*` 用于直接回复，`AI_TASK_*` 用于整理、摘要和后台内容；未单独配置时回退到 `AI_*`。向量服务不可用时仍可做字面、时间和主体检索。

## 本机调试

仅在迁移到 v24 的隔离恢复库运行调试服务后打开 `http://127.0.0.1:8080/ai-debug`。不得用 `npm run dev:cloud-db` 直接写生产库。调试页支持：

- 两位账号与公聊/私聊切换；
- 查看 Agent instructions、输入、工具调用、输出和耗时；
- 按层级与状态查看 Memory 和原文证据；
- 手动整理当前频道的新消息；
- 有明确确认步骤地清除当前频道最近消息。

调试页只在非生产环境且 loopback 请求下可访问。它必须连接隔离恢复库，不能连接生产数据库。
