# CoupleChat AI 架构

本文只描述当前正式架构。服务端只有一条回答链路：OpenAI Agents SDK 负责决策，MCP 提供受控工具，Memory 保存结构化记忆和主人原话证据。

记忆实际库存、迁移、运维和已知边界见 `docs/AI_MEMORY_HANDOFF.md`。

## 1. 总体流程

```text
主人消息写入 PostgreSQL
  ├─ Memory Extractor 增量提取结构化记忆
  ├─ Conversation Context 异步压缩窗口外聊天
  └─ 需要大橘回答时
       └─ Reply Coordinator
            └─ Agent Runtime
                 ├─ Instructions + 对话摘要 + 最近聊天 + 当前问题
                 ├─ 自主调用 MCP 工具
                 └─ 输出 1~3 条回复和可选操作草案
```

公聊只有出现配置的召唤词时回答；AI 私聊每条文字或图片消息都会进入 Agent。每个频道串行处理，积压过多时保留最新请求，单轮超时会释放队列并给出可见反馈。

## 2. 代码结构

| 文件 | 职责 |
|---|---|
| `ai/index.ts` | AI 对外入口、公聊/私聊分流、广播和后台任务触发 |
| `ai/agent/runtime.ts` | Agents SDK、模型 Provider、MCP 连接和 Agent Instructions |
| `ai/agent/replyQueue.ts` | 应答执行、超时、队列、确认卡和来源卡片 |
| `ai/mcp/server.ts` | MCP 服务器创建及本地检索工具编排 |
| `ai/mcp/*Tools.ts` | 通用结果格式、个人事项、图片和联网工具注册器 |
| `ai/mcp/runContext.ts` | 单轮工具身份、调用预算和 Trace 记录 |
| `ai/memory/store.ts` | Memory 读写、版本替代、检索、证据和游标 |
| `ai/memory/extractor.ts` | 新消息增量分类与证据校验 |
| `ai/memory/maintenance.ts` | 状态/计划过期和无效证据的确定性维护 |
| `ai/conversation/search.ts` | 无领域词典的原文候选召回和统计重排 |
| `ai/conversation/context.ts` / `log.ts` | 窗口外摘要、最近聊天窗口和聊天读取 |
| `ai/runtimeState.ts` | 非记忆型 AI 运行状态 KV |
| `ai/background/*` | 日记和推荐；冲突/搭话信号已合并到 Memory 30 条批处理 |
| `ai/accounts.ts` | 两位主人的账号与显示名缓存 |
| `ai/actions/personalItems.ts` | 提醒和备忘确认操作 |
| `ai/debug/routes.ts` / `page.ts` / `trace.ts` | 本机双人聊天和 Trace 调试页 |
| `personalItems/reminderScheduler.ts` | 到期提醒扫描和推送；不属于 AI 推理层 |

## 3. Agent 输入

每轮 Agent 的初始输入包含：

- 当前北京时间；
- 当前说话人和 username；
- 当前频道及隐私属性；
- 窗口外聊天摘要；
- 最近 14 条聊天；
- 当前问题或当前图片提示。

工具调用结果由 Agents SDK 在同一轮后续 turn 中追加，不重复塞进初始 User Input。

### 3.1 上下文压缩

`conversation/context.ts` 将滑出最近窗口的消息异步压缩到 `ai_runtime_state`：

- 每个频道独立维护摘要；
- 每累计 12 条窗口外消息合并一次；
- 只保留明确事实、决定、时间地点、未完成事项和仍在进行的话题；
- 摘要最多注入 900 字符；
- 最近聊天始终优先于摘要。

摘要不是长期记忆，也不作为敏感事实的最终证据。

## 4. Memory

### 4.1 记忆层

| 层 | 内容 | 更新方式 |
|---|---|---|
| `fact` | 身份、偏好、习惯、健康禁忌、重要人物等稳定事实 | 同 key 新版本替代旧版本 |
| `event` | 用药、就医、旅行、见面、争执、购买等发生过的事情 | 追加；同一证据重复抽取幂等 |
| `plan` | 未来安排、承诺和准备做的事情 | 同 key 更新，可设置有效期 |
| `state` | 生病、忙碌、情绪、正在旅行等短期状态 | TTL 到期自动失效 |
| `relationship` | 双方明确表达的关系身份、共同约定和边界 | 同 key 更新 |
| `insight` | 多条消息共同支持的谨慎模式观察 | 同 key 更新，回答时必须弱化表达 |

原始消息构成证据层，不复制为另一套聊天记忆。

### 4.2 数据表

#### `ai_memory`

保存六层统一记忆：

- `layer / scope / memory_key`：类型、权限范围和稳定版本键；
- `subjects_json / speakers_json`：记忆主体和原始说话人；
- `content / category`：原子化内容和分类；
- `confidence / importance`：可信度和重要度；
- `occurred_at / occurred_end_at`：事件时间；
- `valid_from / valid_until`：有效期；
- `status / supersedes_id`：版本状态；
- `metadata_json / embedding`：扩展信息和向量；
- `created_at / updated_at`：时间戳。

#### `ai_memory_evidence`

在线新增记忆必须关联主人原始消息；旧迁移卡使用 `trusted_legacy_card` 例外策略：

- `memory_id / message_id`；
- `channel / sender / message_ts`；
- `excerpt / evidence_role`。

#### `ai_memory_cursor`

每个频道保存已完成提取的 `(cursor_ts, cursor_id)` 游标。只有整批消息分类、校验和写入全部成功后才推进游标。

#### `ai_runtime_state`

保存会话摘要和每日推荐等可重建运行状态，不属于长期 Memory。

### 4.3 增量提取

```text
新主人文字消息
  → 8 秒轻量防抖检查
  → 累计游标后的主人文字，不足30条时不调用 LLM
  → 每批固定取最早30条
  → 向模型提供当前有效记忆和新消息
  → 模型输出 0~30 条变更
  → 校验 operation / targetMemoryId / layer / subjects / sourceMessageIds
  → 使用证据消息确定事件时间和有效期
  → 生成 embedding
  → 事务内去重、版本替代、写记忆与证据
  → 推进游标
  → 公聊同批输出 none/conflict/interject 候选信号
  → 达阈值时交给 Agent + MCP 复核并决定回复或沉默
```

提取器拒绝保存问句本身、AI 旧回答、无明确答案的猜测、玩笑和辱骂中的人格判断。

Debug 的“立即整理”可强制处理不足 30 条的当前积压。单批保留每条新消息最多 800 字，当前记忆每条最多注入 240 字，避免 30 条批次挤爆模型上下文。提取输出最多 30 条变更、上限 4,000 tokens；JSON 截断或无效时不推进游标。

冲突检测和主动搭话不再单独调用 task 模型。Memory 批处理只产生不可信候选，不生成回复、不把检测 reason 写入记忆。conflict >= 0.70 或 interject >= 0.78 才进入公聊 Agent；Agent 可调用 MCP 复核，也可输出空 replies 保持沉默。冲突冷却 15 分钟，搭话冷却 2 小时。

### 4.4 更新与纠错

记忆提取输出的是变更集，而不是只会追加的卡片：

| operation | 行为 |
|---|---|
| `upsert` | 新增主题，或使用 `targetMemoryId` 更新已有事实、计划、状态、关系和洞察 |
| `append` | 追加一个新事件 |
| `retract` | 主人明确否定或纠正已有记忆 |
| `complete` | 将已有计划标记为完成 |
| `cancel` | 将已有计划标记为取消 |

更新已有记忆时，提取器必须引用当前有效记忆的 `targetMemoryId`。存储层强制复用目标的 `memoryKey`，因此不依赖模型再次生成完全相同的 key。

代码还执行以下强校验：

- 洞察至少需要三条本批新消息证据，且置信度最高为 0.75；
- 所有证据必须是仍存在的主人消息；
- complete/cancel 只能作用于计划；
- 状态默认 72 小时有效，计划默认 30 天有效；模型可根据明确期限给出更合适的有效期；
- 主人撤回消息时，对应证据标记为 retracted；失去全部支持证据的有效记忆同步撤回；
- 服务启动和每小时执行一次确定性维护，过期状态/计划以及无有效证据的记忆会退出 active 状态。

## 5. MCP 工具

| 工具 | 用途 |
|---|---|
| `search_facts` | 稳定事实、身份、偏好、健康、习惯和重要人物 |
| `search_events` | 过去经历和发生时间 |
| `search_plans` | 未来安排、承诺和计划 |
| `get_current_states` | 当前短期状态 |
| `get_relationship_context` | 关系身份、共同约定和边界 |
| `search_insights` | 分析或复盘时读取谨慎观察 |
| `get_people_context` | 两位主人的结构化事实概况 |
| `get_memory_evidence` | 回看一条 Memory 的主人原话 |
| `search_chat_messages` | 搜索原始聊天证据并返回相邻上下文 |
| `get_messages_around` | 扩大某条消息的前后文 |
| `list_personal_items` | 查询当前可见提醒和备忘 |
| `draft_personal_item_action` | 生成需要主人确认的事项操作草案 |
| `inspect_recent_image` | 识别当前或最近图片 |
| `web_search` | 查询最新外部信息并收集来源 |

### 5.1 原文搜索

原文搜索不维护生日、旅行、用药等领域词典，也不在代码里逐个补同义词。

Agent 根据当前问题提供：

- `query`：一个核心概念；
- `alternatives`：需要发散时生成的少量不同表达；
- `sender / from / to`：人物和时间约束；
- `match`：默认 `hybrid`，精确核对同一句原话时可用 `all`。

搜索内核统一执行：

1. 中文运行时分词；
2. 多查询 OR 候选召回；
3. 基于候选集合计算词项逆频率；
4. 按稀有词命中、覆盖率、短语命中和时间重排；
5. 默认返回前三个命中的前后各两条上下文。

语义发散属于 Agent 的推理能力，搜索内核只负责通用检索和排序。

## 6. 权限

- 公聊只能读取 `couple` 原始消息、Memory 和 shared 事项；
- AI 私聊可以读取 `couple` 与当前主人的私聊数据；
- 任何工具都不能读取另一位主人的 AI 私聊；
- 原文证据搜索排除大橘历史回复和当前问题；
- MCP 不暴露任意 SQL、任意 URL 图片识别或通用数据库 CRUD；
- 提醒和备忘写操作必须先生成确认草案，主人确认后才执行。

## 7. 回答与证据规则

- 普通闲聊无需调用工具；
- `search_events` 命中可直接作为事件事实，不再取 evidence 或原聊天；
- 旧迁移卡以 `evidencePolicy=trusted_legacy_card` 标记，不要取 evidence；
- 在线新增的非事件敏感记忆按需使用主人原话证据；
- 结构化记忆不足时搜索原始聊天；
- 搜索命中问题本身不等于找到答案；
- 工具只返回有限候选，不能声称扫描了全部历史；
- 没有可靠证据时明确说无法确认，不能脑补；
- 大橘自己的旧回答不能作为事实证据。

## 8. Trace 与本机调试

开发环境访问：

```text
http://127.0.0.1:8080/ai-debug
```

页面支持两位主人、公聊/AI 私聊切换和真实消息写入。登录 token 保存在浏览器本机存储，刷新后会先验证并自动恢复。

每轮 Trace 只展示当前正式链路：

1. Agent 与 MCP 工具；
2. Agent Instructions；
3. Agent 初始输入；
4. 最终输出；
5. 阶段耗时。

Memory 调试接口：

```text
GET  /api/ai-debug/memory/stats
GET  /api/ai-debug/memory
POST /api/ai-debug/memory/flush
DELETE /api/ai-debug/messages/recent
```

页面中的 Memory 观察台可以按层级和生命周期状态查看记忆、key、主体、置信度、重要度以及主人原话证据，也可以手动触发当前频道的增量整理。

“迁移”面板每两秒读取 `ai_memory_import_runs` 的后台进度，显示模型、已处理数量、候选、错误、各审核状态及原文证据。`needs_review` 和 `verified` 候选可以在面板中批准或拒绝；批准只改变暂存状态，仍需显式执行发布命令才会进入正式 Memory。

“清除最近聊天”只允许在本机调试环境调用，可删除当前公聊或当前账号 AI 私聊最近 20～200 条消息。清除后同时重置该频道的压缩摘要与 Memory 游标；失去全部有效证据的记忆会自动撤销。

## 9. 配置

Agent 使用 `AI_CHAT_*`，后台提取和摘要使用 `AI_TASK_*`；只配置 `AI_*` 时两者共享同一个 Provider。

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

AI_MCP_URL=http://127.0.0.1:8080/api/ai-mcp
```

向量服务使用 `EMBEDDING_*` 配置。未配置向量服务时，Memory 仍可进行字面检索和时间、主体过滤。

## 10. 历史数据档案

以下三张表保留原始数据和审计来源，已完成正式 Memory 迁移，不参与当前 Agent、Memory、主动插话或每日推荐运行时：

- `ai_facts`；
- `ai_episodes`；
- `ai_docs`。

不得删除、覆盖或把这些表直接混入回答证据。正式记忆以 `ai_memory_import_candidates.published_memory_id` 反查迁移来源。

### 10.1 历史 Memory 迁移工具

迁移脚本把旧卡转换为当前结构，并把模型结果写入 `ai_memory_import_*` 暂存表。事件卡按“频道+日期”合并，每次模型请求默认最多 10 张卡，默认每卡生成一条、最多两条原子记忆；默认只生成候选，不直接写正式 Memory。

```bash
# 每次处理 20 条旧事实
npm run memory:import -- --source=facts --limit=20

# 处理 20 个“频道+日期”批次；同一天的旧事件卡共用一次模型请求
npm run memory:import -- --source=episodes --limit=20

# 事件迁移默认 24 并发，也可按模型限流情况调整（最高 48）
npm run memory:import -- --source=episodes --limit=100 --concurrency=32

# 人工批准或拒绝单条候选
npm run memory:import -- --approve=mic_xxx
npm run memory:import -- --reject=mic_xxx

# 只发布 verified 或 approved 候选
npm run memory:import -- --publish --limit=50
```

迁移模型默认使用 `deepseek-v4-flash`，可以独立配置：

```env
AI_MIGRATION_BASE_URL=
AI_MIGRATION_API_KEY=
AI_MIGRATION_MODEL=deepseek-v4-flash
```

未单独配置 URL 和 key 时复用 `AI_TASK_*` 或 `AI_*`，但仍使用独立的迁移模型名。能找到原文的候选会保存真实 `messageId`；无法自动验证的旧卡则以较低置信度进入 `needs_review`，有候选原文时默认约 0.45，完全没有原文时约 0.30。健康、身份、关系、边界和洞察始终进入人工审核。

人工批准且没有原文的候选发布后会在 `metadata_json` 中标记 `legacyReviewed=true` 和 `provenance=legacy_manual_approval`，不会伪装成具有主人原文证据的正常记忆。
