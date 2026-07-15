# 大橘 AI 系统

> 系统只服务 `xu/si`。配置兼容的非 Claude 对话模型时，两位用户使用 OpenAI Agents SDK、MCP、历史检索与自动 Memory；直接生成任务同时支持 Responses、Chat Completions 和 Anthropic Messages。数据通过 conversation/account/couple ownership 约束，Memory 还区分“关于主人”和“大橘自己”的动态记忆。

## 回答链路

```text
`xu/si` 主人消息写入 PostgreSQL
  ├─ 增量整理 Memory
  ├─ 更新窗口外对话摘要
  └─ 需要回复时
       → ReplyQueue
       → OpenAI Agents SDK（兼容的非 Claude 对话模型）
       → MCP 工具（按需）
       → 1～3 条回复 / 确认卡 / 来源卡片
       → 消息入库并广播
```

`couple` 频道仅在出现 `AI_TRIGGER_ALIASES` 时直接回答；个人 `ai` 频道每条文字或图片都进入回答链路。每个频道串行执行，超时会释放队列并提供可见反馈，积压时保留最新请求。

未配置任何 `AI_*` provider 时，公聊被明确召唤和 AI 私聊仍会返回内置兜底文本；配置了 provider 但 Agent 不兼容或单轮失败时，会写入可见的失败/重试提示。Memory 提取、摘要、推荐等直接生成任务通过 `provider.ts` 执行，不依赖 Agent runtime。

## 代码位置

| 路径 | 职责 |
|---|---|
| `server/src/ai/index.ts` | 入口分流、消息广播和后台触发 |
| `agent/runtime.ts` | Agent instructions、模型和 MCP 连接 |
| `agent/replyQueue.ts` | 队列、超时、多条回复和确认卡 |
| `mcp/` | 工具服务器、单轮身份、预算和工具实现 |
| `memory/store.ts` | Memory 生命周期、检索、派生来源和向量 |
| `memory/extractor.ts` | 新消息增量整理与强校验 |
| `memory/maintenance.ts` | 近况/计划过期和向量维护 |
| `conversation/` | 最近消息、上下文摘要和原文搜索 |
| `debug/` | 本机 Trace 与 Memory 调试页 |

## Agent 输入

完整 Agent 每轮初始输入包含北京时间、说话人、频道权限、窗口外摘要、最多 50 条原文和当前问题。其中最后 8 条是重点上下文，更早的最多 42 条只作低优先级辅助；私聊累计到 50 条后把滚出重点窗口的内容写入摘要，公聊则在每次大橘会话完成后更新会话摘要。工具结果由 Agent 在同一轮继续处理，不重复塞进初始输入。

窗口外摘要保存在 `ai_runtime_state`，它是可重建的短期上下文，不是长期事实。

## Memory

| 层 | 内容 | 生命周期 |
|---|---|---|
| `fact` | 身份、偏好、习惯、健康等稳定事实 | 同 key 更新 |
| `event` | 已发生的重要事情 | 追加、内容幂等 |
| `plan` | 未来安排和承诺 | 可完成、取消或过期 |
| `state` | 近三天活动、健康、情绪和讨论等详细近况 | 按人物滚动更新并归档旧版 |
| `relationship` | 最近关系状态、亲密/疏离与争执原因 | 从基础记忆滚动生成 |
| `insight` | 沟通偏好和反复出现的互动模式 | 从多张基础记忆谨慎生成 |

当前候选运行表：

- `ai_memory`：结构化内容、状态、范围、置信度、时间和 embedding；
- `ai_memory_cursor`：每个 conversation 已整理到的 `(cursor_ts, cursor_id)`，保留 legacy channel 兼容键；
- `ai_memory_dependencies`：关系与理解卡引用的基础记忆；
- `ai_memory_exclusions`：用户忘掉后按卡片 key 阻止重新生成；
- `ai_runtime_state`：上下文摘要和派生记忆维护游标等可重建状态。

`ai_memory.perspective` 区分 `people` 与 `daju`，`memory_kind` 区分 `standard`、`instruction` 和 `observation`。主人在当前对话中明确提出长期的大橘行为要求时，由回复 Agent 理解整句话并直接调用 `save_daju_instruction` 写入，不使用关键词规则，也不等待批量整理；仅当前一次的临时要求和推断偏好不会保存。大橘观察仍由后台整理器生成，必须引用至少两张基础记忆卡，并按有效期自动过期。普通人物检索默认只看 `people`，大橘行为要求由 Agent 自动注入，观察仅在复盘、分析和调解时按需读取。

整理器按游标读取最多 80 条主人消息。达到 80 条立即整理；20 条以上在空闲 15 分钟后整理，20 条以下空闲 60 分钟后整理，最老消息等待满 2 小时也会整理。整理器读取整段聊天作为当次上下文，但卡片落库后不保存原始消息 ID、摘录或引用。无效 JSON 或写入失败不能推进游标。

关键规则：

- AI 自己的回答不会进入基础记忆整理输入；
- 撤回聊天不会自动删除已经生成的记忆，错误记忆由控制中心纠正或忘掉；
- 关系与理解不读取聊天原文，只引用事实、经历、计划和近况卡；
- 公聊只读取双方公开数据，私聊可额外读取当前用户私聊；
- 不确定时明确表示无法确认，不能把搜索候选写成确定事实。

### App 内控制中心

生产登录用户可通过 `我的 → 大橘与记忆` 管理自己可见的 Memory：

- 共同范围按 `couple_id` 隔离；个人范围按 `account_id` 隔离，legacy scope 字符串只保留兼容，不能跨账号读取私聊。
- 顶部只提供全部、两人可见、仅自己和大橘四个入口；普通记忆按层级分类，大橘入口只分指令与观察。
- 手动纠正正文时记录修改者和时间、清空旧 embedding，后续维护任务会重新生成向量。
- “忘掉”物理删除 Memory 行并按卡片 key 写 exclusion，原聊天消息保持不变。
- 可以分别立即整理共同聊天和当前账号的 AI 私聊。
- 列表已支持 cursor 分页、版本冲突和 Sync V2 跨设备刷新。

Memory 本地离线缓存尚未完成；runtime/tool 以 `conversation_id/couple_id/account_id` 为边界。

## MCP 工具

- 分层 Memory 检索，以及关系/理解的基础记忆来源读取
- 大橘行为要求直接写入、已有要求读取，以及观察按需读取；观察结果明确标记为假设，不作为主人事实
- 原始聊天搜索及相邻上下文
- 当前用户可见提醒/备忘查询
- 需要确认的提醒/备忘完整增删改草案；修改与删除先查询准确 id
- 当前或最近图片理解
- 联网搜索和来源收集

工具不提供任意 SQL、任意数据库 CRUD 或跨用户私聊读取。
事项动作始终以当前登录账号授权，模型给出的 `ownerName` 不能变成另一账号身份；shared 变更同步双方，personal 只作用于当前账号。结构化回答会主动使用合法 Markdown 标题、列表或表格，普通闲聊保持自然文本。

## 今日推荐

推荐生成不走对话 Agent，而是 `server/src/daily/recommendationService.ts` 调用 task provider：

- 作息日按北京时间 06:00 切换；调度器启动后立即检查，此后每 15 分钟幂等执行，`today` API 也会懒生成。
- 优先读取昨天共同 `event`，再用近况 `state`、有效 `plan` 和 `fact` 补充，不读取私人 Memory、`relationship` 或 `insight`。
- 模型必须返回 `{ category, content }`；解析失败或模型不可用时按作息日确定性选择内置推荐。
- 每日大橘推荐双方相同；双方互荐、已读和历史隐藏使用账号级状态，并通过 Sync V2 刷新。

## 配置

配置值保存在环境变量中，不写入仓库：

```env
AI_BASE_URL=
AI_API_KEY=
AI_MODEL=
AI_API_MODE=responses
AI_REASONING_EFFORT=high

AI_CHAT_BASE_URL=
AI_CHAT_API_KEY=
AI_CHAT_MODEL=
AI_CHAT_API_MODE=
AI_CHAT_REASONING_EFFORT=

AI_TASK_BASE_URL=
AI_TASK_API_KEY=
AI_TASK_MODEL=
AI_TASK_API_MODE=
AI_TASK_REASONING_EFFORT=

AI_VISION_BASE_URL=
AI_VISION_API_KEY=
AI_VISION_MODEL=
AI_VISION_API_MODE=

AI_MCP_URL=http://127.0.0.1:8080/api/ai-mcp
AI_TRIGGER_ALIASES=@大橘

TAVILY_MCP_URL=
TAVILY_API_KEY=

EMBEDDING_VOYAGE_PROVIDER=
EMBEDDING_VOYAGE_BASE_URL=
EMBEDDING_VOYAGE_API_KEYS=
EMBEDDING_MONGODB_PROVIDER=
EMBEDDING_MONGODB_BASE_URL=
EMBEDDING_MONGODB_API_KEYS=
EMBEDDING_MODEL=voyage-4
EMBEDDING_DIM=1024
```

`AI_CHAT_*` 用于直接回复，`AI_TASK_*` 用于整理、摘要和后台内容；未单独配置时回退到 `AI_*`。`*_API_MODE` 支持 `responses/chat_completions/anthropic`，未声明时 Claude 模型自动走 Anthropic，其余默认 Chat Completions；Responses 调用失败会在未超时的情况下回退 Chat Completions。`*_REASONING_EFFORT` 支持 `none/minimal/low/medium/high/xhigh`。

当前图片可一次把最多 9 张送入模型。联网优先使用 Responses 原生 `web_search`；MCP fallback 可按国内/国际/交叉核实路由，并可配置 Tavily 做全球搜索和指定网页提取。向量检索支持 Voyage、MongoDB 两个多 key 池顺序 failover，也兼容旧的 `EMBEDDING_BASE_URL/API_KEY` 单 key 配置；向量服务不可用时仍可做字面、时间、主体与高重要度兜底检索。完整生产示例以 `server/.env.production.example` 为准。

## 本机调试

仅在迁移到当前 schema v31 的隔离恢复库运行调试服务后打开 `http://127.0.0.1:8080/ai-debug`。不得用 `npm run dev:cloud-db` 直接写生产库。调试页支持：

- 两位账号与公聊/私聊切换；
- 查看 Agent instructions、输入、工具调用、输出和耗时；
- 按层级与状态查看 Memory；
- 手动整理当前频道的新消息；
- 有明确确认步骤地清除当前频道最近消息。

调试页只在非生产环境且 loopback 请求下可访问。它必须连接隔离恢复库，不能连接生产数据库。
