# 大橘 AI

> 系统只服务 `xu/si`。对话与后台任务统一使用 **OpenAI 兼容**接口（Responses 或 Chat Completions）：回复走 OpenAI Agents SDK + MCP + Memory；整理/摘要/推荐等直接生成任务走 `provider.ts`。数据通过 conversation/account/couple ownership 约束，Memory 还区分“关于主人”和“大橘自己”的动态记忆。

## 回答链路

主人消息落库后由 `pipeline.dispatchAfterOwnerMessage` **三线并行**（均不阻塞发送）：

```text
messages 落库
  ├─ 1 day-context   scheduleContextCatchUp（微段 + 作息日总览）
  │                    └─ 公聊微段提交后 → engagement 本地门闩 → 可选分类模型 → 可选后台 Agent
  ├─ 2 long-memory   onMemoryMessage（批处理；寒暄跳过模型仍推进游标）
  └─ 3 reply         公聊仅 AI_TRIGGER_ALIASES；私聊仅有文字时答（纯图不答）
                       → ReplyQueue（同频道串行，pending≤5 后 coalesce 最新）
                       → ensureContextCaughtUp → Agent + MCP
                       → createAiMessage + Socket 广播
                       → 再 scheduleContextCatchUp（纳入大橘发言）
```

| 层 | 写哪里 | 读哪里 |
|---|---|---|
| 热窗口原文 | `messages` | Agent user 上下文 |
| 日总览/微段 | `ai_runtime_state` `context:v2:*` | Agent user；engagement |
| 长期 Memory | `ai_memory*` | MCP tools；推荐等 |
| 大橘发言 | `messages` | 同上热窗口 |

未配置 `AI_*` 时，明确召唤与私聊仍回固定不可用文案。Memory/摘要/推荐等 task 走 `provider.ts`，不依赖 Agent runtime。

## 代码位置

| 路径 | 职责 |
|---|---|
| `server/src/ai/index.ts` | 门面：init、Socket sink、handleUserMessage |
| `pipeline.ts` | 主人消息后三线调度 |
| `imageAttachment.ts` | 需要看图时解析本条/最近图组 |
| `agent/runtime.ts` | Agent、多模态注入与工具触发的重跑 |
| `agent/replyQueue.ts` | 队列、超时、多条回复与确认卡 |
| `engagement.ts` | 公聊冲突/搭话（本地预过滤 + 精简分类） |
| `textSignals.ts` | 低信息量文本判定（上下文与 Memory 共用） |
| `mcp/` | 工具、单轮身份、预算 |
| `memory/store.ts` | Memory 持久化与检索 |
| `memory/extractor.ts` | 批处理整理 |
| `memory/maintenance.ts` | 生命周期与 embedding 补齐 |
| `conversation/context.ts` | day-digest-v2、微段、热窗口 |
| `debug/` | 本机 Trace / Memory 调试页 |

## Agent 输入

完整 Agent 每轮初始输入包含北京时间、说话人、频道权限、**今日聊天总览**、可选时段要点、最近原文和当前问题。

| 层 | 内容 | 作用 |
|---|---|---|
| 今日聊天总览（Day Digest） | 作息日（北京 06:00 切日）内的话题卡、决定、未决、情绪线 | 晚上仍能知道早上聊过什么的大概 |
| 较早时段要点 | 最近若干微段 bullets | 中等粒度时间线 |
| 热窗口原文 | 最近 40 条，其中最后 16 条为重点 | 指代、语气、刚说完的细节 |

上下文维护在 `conversation/context.ts`（strategy `day-digest-v2`）：

- 公聊与私聊同一套；**消化双方全部有效聊天**，不再只摘要「大橘会话」。
- 约每 40 条有效消息（或空闲 10 分钟 / 最老消息 45 分钟）压成微段，再折入当日总览；贴纸与短寒暄（嗯/哈哈等）不计入微段。
- 任意主人消息后防抖调度追赶；Agent 回答前强制追赶（约 25s 预算）；落后时在 prompt 中提示可用 `search_chat_messages`。
- 日切后昨日总览归档；Agent 输入可带【昨日话题标题】一行（无细节）。
- 状态保存在 `ai_runtime_state`（`context:v2:{channel}`），可重建，不是长期事实库；跨天稳定事实仍靠 Memory。

### 公聊冲突 / 主动搭话

与 Memory 批处理解耦，实现见 `server/src/ai/engagement.ts`：

- **触发**：公聊微段写入并折入当日总览之后（跟上下文追赶节奏，而不是 80 条记忆批）。
- **检测输入（精简）**：当日总览压缩版 + 本段 bullets + 最近约 14 条 compact 原文；不读整批聊天全文。
- **输出**：`none | conflict | interject` + confidence + 短 reason；阈值与冷却（conflict 15 分钟 / interject 2 小时）后再排队 Agent。
- **开口上下文**：只带 reason、话题提示、段要点与短原文；Agent 另有完整【今日聊天总览】+ 热窗口，不再灌 80 条主人消息。
- **日志**：`[engagement] decision=...`（none / suppressed_threshold / suppressed_cooldown / emit）。

工具结果由 Agent 在同一轮继续处理，不重复塞进初始输入。

### Token 纪律（实现约定）

- Agent system 只保留总则；工具细则以 MCP tool description 为准，MCP server.instructions 保持极短。
- 行为要求预注入 user 后，默认不再调用 `get_daju_instructions`。
- 后台介入线索不附带最近原文（热窗口已有）；Memory 批处理单条正文截断；日总览合并只送瘦身 JSON。
- 输出预算：`GEN.reply` 等见 `settings.ts`，避免为闲聊预留过大 maxTokens。

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

整理器按游标读取最多 80 条主人消息，基础提取模型只接收这批新消息，不再附带旧 Memory 正文，并使用独立的低推理强度与 120 秒上限，不继承对话任务的高推理配置。达到 80 条立即整理；20 条以上在空闲 15 分钟后整理，20 条以下空闲 60 分钟后整理，最老消息等待满 2 小时也会整理。模型输出 `memoryKey` 后，服务端先规范化再入库：people 标准卡为 `{layer}.{subject}.{topic}`；`state` 固定 `state.{subject}.recent`；`relationship` / 人物 `insight` 固定滚动键；大橘指令 `daju.instruction.{topic}`、观察 `daju.observation.{topic}`。随后按层处理：`fact/plan` 先做精确 key 匹配，未命中时才用同层同主体向量候选更新；`state` 按主体滚动；`event` 追加并以 key+内容幂等。关系与理解在基础卡写入后由独立派生阶段生成；大橘观察只允许引用本批实际写入的至少两张基础卡。卡片落库后不保存原始消息 ID、摘录或引用。无效 JSON 或写入失败不能推进游标。

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
- 模型必须返回 `{ category, content }`；生成时会把最近 12 条大橘推荐作为排除项，移除带具体作品名的格式示例，并对同一明确对象和高文本相似结果做有限重试。解析失败、模型不可用或连续重复时，内置推荐也会跳过近期对象后轮换。
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

# 通常留空；服务端会按当前 PORT 派生 loopback /api/ai-mcp
AI_MCP_URL=
AI_TRIGGER_ALIASES=@大橘

EMBEDDING_VOYAGE_PROVIDER=
EMBEDDING_VOYAGE_BASE_URL=
EMBEDDING_VOYAGE_API_KEYS=
EMBEDDING_MONGODB_PROVIDER=
EMBEDDING_MONGODB_BASE_URL=
EMBEDDING_MONGODB_API_KEYS=
EMBEDDING_MODEL=voyage-4
EMBEDDING_DIM=1024
```

`AI_CHAT_*` 用于直接回复，`AI_TASK_*` 用于整理、摘要和后台内容；未单独配置时使用 `AI_*`。`*_API_MODE` 仅支持 `responses` / `chat_completions`（OpenAI 兼容），未声明时默认 Chat Completions；不再提供 Anthropic 原生协议分支。服务端只执行配置指定的协议，不在失败后切换另一套模型协议。`*_REASONING_EFFORT` 支持 `none/minimal/low/medium/high/xhigh`。

**图片理解**：统一用对话主模型多模态，**不再使用独立 `AI_VISION` 转写**。

| 场景 | 行为 |
|---|---|
| 纯图、无文字说明 | **不自动回复**（公聊/私聊都等用户再发文字提问） |
| 本条有图且有文字 | 图与问题作为 `input_image` 一并进主模型 |
| 先发图再发文字（问题明确在问图） | 开跑前预附着最近一组图（≤9）+ 问题；预判已收紧，避免闲聊误带图 |
| 预判未附着但 Agent 仍要看图 | `inspect_recent_images` 解析 URL 后 **多模态重跑**（问题+图） |

联网只使用 Responses 原生 `web_search`。向量检索支持 Voyage、MongoDB 多 key 池 failover；向量不可用时仍可字面检索。完整示例见 `server/.env.production.example`。

## 本机调试

仅在迁移到当前 schema v31 的隔离恢复库运行调试服务后打开本地 `http://127.0.0.1:8080/ai-debug`（若本地修改 `PORT`，地址随之变化）。连接生产库启动本地调试服务的入口已移除。调试页支持：

- 两位账号与公聊/私聊切换；
- 查看 Agent instructions、输入、工具调用、输出和耗时；
- 按层级与状态查看 Memory；
- 手动整理当前频道的新消息；
- 有明确确认步骤地清除当前频道最近消息。

调试页只在非生产环境且 loopback 请求下可访问。它必须连接隔离恢复库，不能连接生产数据库。Trace 最多保留当前进程内最近 100 条，进程退出即清空，不写入磁盘。
