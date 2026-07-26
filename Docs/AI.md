# 大橘 AI

只服务 `xu/si`。统一走 OpenAI 兼容接口：回复用 Agents SDK + MCP + Memory，
整理/摘要/推荐等任务直接走 `provider.ts`。数据按 conversation/account/couple
归属约束。

## 回答链路

主人消息落库后由 `pipeline.dispatchAfterOwnerMessage` 三线并行（不阻塞发送）：

```text
messages 落库
  ├─ 上下文     微段 + 作息日总览（公聊微段提交后可触发主动搭话/冲突介入）
  ├─ 长期记忆   批处理整理（低信息量消息跳过模型仍推进游标）
  └─ 回复       公聊需 @大橘；私聊有文字才答（纯图不答）
                 → ReplyQueue（同频道串行）→ Agent + MCP
                 → createAiMessages（多段回复同一事务）→ Socket 广播
```

**持久回复任务**（v36）：每条主人消息在同一事务插入 `ai_reply_jobs`；不触发的
标记 `ignored`，触发的经 `queued → processing` 租约领取，最多 5 次重试。写回复
时重新校验 requester/conversation/channel 并 `FOR UPDATE` 锁 job，全部分段与
`completed` 同一事务提交。启动先监听 HTTP，再异步释放上一进程租约并恢复任务；
30 秒周期扫描兜底。撤回会取消对应的排队/运行中任务。

**超时阶梯**：单次 MCP 调用 20s < Agent run 100s（`GEN.reply.timeoutMs`）<
队列兜底 120s < 任务租约 180s。改任何一档要保持这个顺序。

## Agent 输入

每轮预注入（都在 user 消息里，模型不用调工具就能看到）：

| 块 | 内容 |
|---|---|
| 大橘行为要求 | 当前 requester + `both` 的指令，最多 12 条 |
| 你已经记住的 | 每人最新一张近况 state + 最重要的 5 条 fact |
| 今日聊天总览 | 作息日（北京 06:00 切日）话题卡、决定、未决 |
| 热窗口原文 | 最近 40 条，末 16 条为重点 |

system prompt（`agent/runtime.ts` 的 `instructions`）的核心规则：涉及主人的
身份、偏好、经历、计划就**先查记忆再回答**，拿不准就查；证据顺序为主人当前
原话 > 最近原文 > 今日总览 > 记忆卡；查不到就明说，禁止脑补。

上下文由 `conversation/context.ts` 维护（`day-digest-v2`）：约 40 条有效消息
（或空闲 10 分钟）压一个微段，增量补丁折入当日总览；状态存 `ai_runtime_state`，
可重建。跨日积压按顺序逐日消费。大橘日记由调度器每小时幂等确保上一作息日
（读整日 couple 公聊，不读私聊；已有日记幂等返回，显式 `force` 才重写）。

公聊**主动搭话/冲突介入**（`engagement.ts`）：微段提交后本地门闩 → 分类模型 →
阈值 + 冷却（conflict 15 分钟 / interject 2 小时 / 跨类型 5 分钟）→ 后台 Agent
候选，可输出空回复保持沉默。

## Memory

| 层 | 内容 | 生命周期 |
|---|---|---|
| `fact` | 身份、偏好、习惯、健康 | 同 key 更新 |
| `event` | 已发生的重要经历 | 追加，key+内容幂等 |
| `plan` | 未来安排承诺 | 可完成/取消/过期 |
| `state` | 近三天滚动近况 | 按人滚动，72h TTL |
| `relationship` / `insight` | 从基础卡派生的关系与理解 | 周期重建 |

表：`ai_memory`（内容 + embedding）、`ai_memory_cursor`（每频道整理游标）、
`ai_memory_dependencies`（派生卡引用）、`ai_memory_exclusions`（忘掉的排除项）。

**整理器**（`memory/extractor.ts`）：按游标批读最多 80 条主人纯文本消息送模型；
80 条立即整理，20+ 条空闲 15 分钟，更少空闲 60 分钟，最老消息满 2 小时强制。
`memoryKey` 规范为 `{layer}.{subject}.{topic}`。整理不出内容时保留游标重试，
**连续 3 轮无产出则强制推进游标并告警**——宁可漏一批，不能永久堵死。

**忘掉**：物理删除该行，排除项一律按 **key + 内容指纹**记录——被删的那版内容
不再复活，同主题的新信息照常写入。依赖它的派生卡同事务删除并发 Sync delete。

关键规则：AI 自己的话不进整理输入；撤回消息不自动删已生成的记忆；公聊只读
双方公开数据，私聊可加读本人私聊；不确定就说无法确认。

App 内控制中心（我的 → 大橘与记忆）：分范围/层级浏览、纠正、忘掉、手动整理，
带 `baseVersion` 冲突处理，变更走 Sync V2 跨设备刷新。

## MCP 工具

分层记忆检索、行为要求读写、聊天原文搜索、提醒/备忘查询与确认草案
（增删改一律先出草案、用户点确认才执行）、图片理解（`inspect_recent_images`
触发多模态重跑）、联网搜索。不提供任意 SQL、跨用户私聊读取。工具日志只记
工具名/状态/耗时，不记参数与结果。

图片：纯图不自动回复；本条带图或问题明显在问图时随问题一并进模型；预判
未附着但 Agent 要看图时才调工具重跑。

## 今日推荐

`daily/recommendationService.ts` 走 task provider（不走对话 Agent）：北京时间
06:00 切日，每 15 分钟幂等补建，`today` API 懒生成。优先读昨天共同 `event`，
排除最近 12 条已推荐，双方看到相同内容。

## 配置

环境变量（完整示例见 `server/.env.production.example`）：

```env
AI_BASE_URL= / AI_API_KEY= / AI_MODEL= / AI_API_MODE=responses
AI_CHAT_*（对话）与 AI_TASK_*（整理摘要）可分开配，缺省用 AI_*
AI_TRIGGER_ALIASES=@大橘
EMBEDDING_*（Voyage / MongoDB 多 key 池）、EMBEDDING_DIM 必须与上游一致
```

`*_API_MODE` 支持 `responses` / `chat_completions`；联网搜索只在 Responses
模式可用。向量不可用时仍可字面检索。

## 本机调试

`/ai-debug` 只在非生产 + loopback 可见，必须连接隔离恢复库（不能连生产）。
支持查看 Agent 输入/工具调用/输出、按层浏览 Memory、手动整理。Trace 只留
进程内最近 100 条，不落盘。
