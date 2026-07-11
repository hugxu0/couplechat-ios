# AI Memory 系统交接

> 审查日期：2026-07-11。本文是 AI 记忆、检索、更新和旧库迁移的运维交接；总体 Agent 架构见 `docs/AI.md`。

## 1. 当前状态

系统现在只有一套正式长期记忆：`ai_memory` + `ai_memory_evidence`。`ai_facts` / `ai_episodes` / `ai_docs` 只作为旧数据档案，Agent 不直接读取。

2026-07-11 当前库审计：

| 项目 | 数量 |
|---|---:|
| 旧事件卡源数 | 4,383 |
| 已发布 episode 候选 | 4,469 |
| 已发布 legacy fact 候选 | 74 |
| 被新策略替代、仅留审计的早期候选 | 1,862 |
| 正式 active Memory | 4,543 |
| active 分层 | event 4,395 / fact 58 / insight 16 / relationship 74 |
| active 缺失 embedding | 0 |
| 非 event 重复 active key | 0 |
| 悬空 evidence | 0 |
| 未受信且无有效 evidence 的 active Memory | 0 |

历史 plan/state 已统一归类：过期日程转 event，稳定偏好转 fact，长期共同约定转 relationship，观察性描述转 insight。当前没有无 TTL 的 active plan/state。

## 2. 数据流

```text
主人文字消息
  -> 8s 轻量 debounce 检查
  -> 按 (ts, id) 累计主人文字，不足30条不调 LLM
  -> 每批取最早30条（AI回复/媒体/系统消息不计数）
  -> LLM 输出最多 30 条变更
  -> 代码校验层级、主体、目标和证据 ID
  -> 生成 embedding
  -> 事务写入 Memory + evidence
  -> 推进 (ts, id) 游标
  -> 公聊同时产生 none/conflict/interject 候选
  -> 达阈值后交给 Agent + MCP 复核，Agent 可回复或沉默
  -> 成功处理30条后立即检查下一批
```

失败时不推进游标，30 秒起指数退避，最长 5 分钟。只有成功处理的30条批次才会立即续跑，避免 LLM 错误时快速重试消耗 token。Debug “立即整理”会强制处理不足30条的积压。

上下文预算：30 条新消息每条最多 800 字；最多 160 条 active Memory 每条 content 最多 240 字。所有 30 条消息都保留独立 ID，不会用单一尾部截断把后续消息整条丢掉。输出最多 30 条变更、上限 4,000 tokens；JSON 截断或无效时不推进游标。

公聊 engagement 不额外调用 task 模型，也不写入 Memory。conflict 阈值 0.70、冷却 15 分钟；interject 阈值 0.78、冷却 2 小时。达阈值只表示“提交 Agent 候选”，最终发言必须经过统一 Agent 证据纪律；后台 Agent 失败或超时时保持沉默。

## 3. 分层与更新

| Layer | 语义 | 生命周期 |
|---|---|---|
| `fact` | 身份、偏好、习惯、健康禁忌、重要人物 | 同 key 新版本 supersede 旧版本 |
| `event` | 已发生经历 | 追加；相同内容+证据幂等 |
| `plan` | 未来安排或承诺 | 默认30天，可 complete/cancel/expire |
| `state` | 短期近况 | 默认72小时，到期 expire |
| `relationship` | 明确关系身份、共同约定、边界 | 同 key 版本替换 |
| `insight` | 至少3条新消息支持的谨慎观察 | 同 key 版本替换，confidence <= 0.75 |

LLM 只提交 `upsert / append / retract / complete / cancel`。存储层会锁定 active 目标、复用旧 `memoryKey`，不依赖模型生成完全相同的 key。

主人撤回消息时，evidence 改为 `retracted`；失去所有支持证据的在线 Memory 同步撤回。服务启动和每小时执行生命周期维护，同时每次最多修复 25 条缺失向量的 active Memory。

## 4. Evidence 规则

在线新记忆必须有真实主人消息 evidence。旧迁移卡本身是已经审核、已发布的历史事件事实，统一标记：

```json
{"importedFromLegacy":true,"evidencePolicy":"trusted_legacy_card"}
```

- `search_events` 返回的是可直接回答的事件事实；命中后不调 `get_memory_evidence`，不再搜原聊天。
- `trusted_legacy_card` 不要调 `get_memory_evidence`。
- 只有在线新增的非事件敏感信息，才按需用 `get_memory_evidence` 核实。
- 用户明确要求“逐字原话”时，才从事件结果继续到 `search_chat_messages`。

## 5. Agent 检索

人物身份/关系问题的指令顺序是：

```text
search_facts
  -> 空或未回答身份/关系
  -> search_events(同一核心姓名)
  -> facts/events 都无结果时才 search_chat_messages
```

`search_events` 调用上限为每轮 2 次，全部工具每轮最多 8 次。Debug 网站只展示模型实际发起的工具调用；没有 `search_events` 记录就是当轮模型没有调用，不是页面隐藏。

权限是确定性代码约束：公聊只能读 `couple`；AI 私聊可读 `couple` + 当前 `ai:<username>`，不能读另一人私聊。

记忆搜索使用字面命中 + embedding 余弦相似度重排，当前每次最多载入 10,000 条指定层/权限的 active 候选。

## 6. 旧库迁移

`scripts/migrate-legacy-memory.ts` 先写 `ai_memory_import_*` 暂存表，再显式发布到正式 Memory。episode 按“频道+日期”合并，每次模型请求默认最多 10 张卡，默认 24 并发，上限 48。每张卡通常生成 1 条、最多 2 条候选。

```bash
# 增量生成候选
npm run memory:import -- --source=episodes --limit=500 --concurrency=24 --batch-card-max=10

# 重试未完整批次
npm run memory:import -- --source=episodes --limit=500 --retry --concurrency=24

# 新策略替换旧 run；新 run 成功后才将旧候选标为 superseded
npm run memory:import -- --source=episodes --limit=500 --replace-run=mir_xxx --concurrency=24

# 发布 verified/approved，可幂等重跑
npm run memory:import -- --publish --limit=5000 --concurrency=24

# 历史层级归一和向量修复，均可重跑
npm run memory:import -- --normalize-historical-layers
npm run memory:import -- --repair-embeddings --limit=5000 --concurrency=8
```

脚本支持不完整 JSON 尾部恢复，已 verified/approved/published 候选不会被重试删除。发布以 `importCandidateId` 恢复中断状态，不会重复生成正式 Memory。

## 7. 运维与验证

```bash
cd server
npm run typecheck
npm run smoke:postgres
npm run smoke:legacy-import
```

`smoke:postgres` 覆盖 schema migration、`(ts,id)` 游标、Memory 版本/幂等、TTL、计划转移、撤回传播和 legacy 无证据例外。`smoke:legacy-import` 需要本地旧生产快照，验证原始 SQLite -> PostgreSQL 全量转换，不调 LLM。

数据库日常审计至少检查：

1. active Memory 是否存在 `embedding IS NULL`。
2. 非 event 是否存在相同 `(scope, layer, memory_key)` 的多条 active。
3. 在线 Memory 是否失去全部 support evidence。
4. plan/state 是否有 `valid_until IS NULL`。
5. import candidate 的 `published_memory_id` 是否真实存在。

Debug 本机页：`http://127.0.0.1:8080/ai-debug`。“立即整理”会 flush 当前频道；“清除最近聊天”会同时重置摘要和 `(ts,id)` Memory 游标。

## 8. 已知边界

- 在线 event 的 `occurredAt` 来自被引用的证据消息时间。“上周去了医院”这类回溯性自然语言日期尚未解析，会先记为发言时间。
- Agent 是模型自主选工具；工具描述和 Instructions 已强制人物查询回退顺序，但不是硬编码工作流。判断实际行为以 Trace 为准。
- 10,000 候选上限对当前 4.5k 数据充足；单层 active 数量接近该阈值前，应改为 PostgreSQL 全文/pgvector 预召回。
- LLM 是否正确合并“同一段连续事件”仍是语义质量问题；代码限制每批最多 30 条变更、单一话题最多两层，但不能完全消除模型误拆分。
- 迁移脚本已在当前库全量跑通，但 LLM 输出质量没有固定快照测试；重跑新模型或新 prompt 时应使用新 run + 抽样审核，不要覆盖已发布记忆。

## 9. 本次审查修复

- Memory 游标从单时间改为 `(ts,id)`，避免同毫秒消息漏提取。
- 改为累计30条主人文字才调用 LLM，满批自动排空，失败指数退避。
- Debug 清除消息同步回退 `cursor_ts + cursor_id`。
- 消息上下文展开使用 `(ts,id)` 稳定排序。
- 在线缺失 embedding 每小时自动修复。
- 提取上下文优先保留非 event，避免 4k+ 迁移事件挤出当前 fact/relationship。
- 取消 `search_events` / legacy card 与 `get_memory_evidence` 的工具描述冲突。
- 8 条旧 fact 导入的 plan/state 层级残留已归一，embedding 8/8 补齐。
- 旧库全量替换的 `TRUNCATE` 已纳入新 Memory/import/附件外键表，避免 schema 升级后恢复失败或留下旧记忆。
