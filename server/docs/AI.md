# 大橘 AI 系统文档

> 本文档描述 `couplechat-ios` 后端 `server/src/ai/` 的完整 AI 逻辑，供后续维护者（人或 AI）快速理解整个系统如何运转。
>
> 最后更新：2026-07-08（M1~M7 架构丰富化之后）

---

## 一、总览

大橘是这对情侣聊天 App 里的 AI 猫伴侣。它能在被 `@大橘` 召唤时回答、在私聊里每条都答、在 couple 频道后台默默观察是否该插话或介入吵架、帮主人建提醒/备忘、到点用 Bark 推送提醒、每天凌晨整理记忆。

### 1.1 核心架构图

```
                    ┌─────────────────────────────────────────────────────────┐
                    │  aiService.handleUserMessage(io, user, message)          │
                    │  （入口分流，fire-and-forget，不阻塞消息主流程）           │
                    └────────────────────────┬────────────────────────────────┘
                                             │
              ┌──────────────────────────────┼──────────────────────────────┐
              ▼                              ▼                              ▼
      couple 频道                       ai 私聊频道                  （背景管道，仅 couple）
   ┌───────────────────┐         ┌──────────────────┐         ┌────────────────────────┐
   │ 含 @大橘？         │         │ 每条文本/图片都答 │         │ conflictDetector       │
   │  → queueRespond   │         │  → queueRespond  │         │  .maybeCheck()         │
   │ 无 @大橘          │         └──────────────────┘         │ interjector            │
   │  → 不答           │                                      │  .maybeInterject()     │
   └───────────────────┘                                      └────────────────────────┘
              │                                                         │
              ▼                                                         ▼
   ┌────────────────────────────────────────┐              ┌──────────────────────────┐
   │  replyEngine.queueRespond(trigger,sink)│              │ 各自独立 LLM 调用         │
   │  （每频道串行，过载合并为最新请求）      │              │ 命中则主动 emit 一条消息  │
   └────────────────┬───────────────────────┘              └──────────────────────────┘
                    ▼
   ┌─────────────────────────────────────────────────────────────────────┐
   │  replyEngine.respond(trigger, sink)                                  │
   │                                                                      │
   │  1. classifyIntent + generateRetrievalQuery  ← 并行两轮轻量 LLM     │
   │  2. Promise.all:                                                     │
   │     ├─ recallSafe(query)        ← 向量检索 ai_facts + ai_episodes  │
   │     ├─ ensureDailyMood()        ← 今日心情（每天生成一次缓存）      │
   │     ├─ describeLatestImage()    ← needImages 时识图                  │
   │     └─ webSearch(query)         ← needSearch 时联网（返回来源卡片）  │
   │  3. chat() 一轮 LLM 生成 {replies, actions}                          │
   │  4. parseActions → 打包成 confirm meta 挂在最后一条回复              │
   │  5. 逐条 emit（拟人间隔 0.9~1.6s）                                   │
   │  6. traceFlush → .data/ai_logs/reply-trace-YYYYMMDD.log             │
   └─────────────────────────────────────────────────────────────────────┘

   定时任务：
   ┌────────────────────────────┐    ┌─────────────────────────────────────┐
   │ reminderScheduler          │    │ nightly.runDailyMaintenance()       │
   │  每 60s 扫到点提醒 → Bark  │    │  北京时间 06:00 后跑：              │
   └────────────────────────────┘    │  1. 日记 digest                     │
                                     │  2. 事件卡片 episodes               │
                                     │  3. 事实收口 consolidateFacts       │
                                     │  4. 短期记忆重写 short-term         │
                                     │  5. 人物卡 + 关系卡刷新             │
                                     └─────────────────────────────────────┘
```

### 1.2 文件清单

| 文件 | 职责 | 模块 |
|---|---|---|
| `ai/aiService.ts` | 入口分流、回复广播、后台管道触发、启动调度器 | 门面 |
| `ai/replyEngine.ts` | 应答主流程：上下文组装、LLM 调用、逐条发出、actions 确认卡 | 应答 |
| `ai/intent.ts` | 意图判断 + 独立检索词生成（并行） | 意图 |
| `ai/provider.ts` | LLM 客户端：chat / describeImage / webSearch | LLM |
| `ai/persona.ts` | 大橘人格单一来源 | 人设 |
| `ai/memoryStore.ts` | ai_facts / ai_episodes / ai_docs 三张表的全部读写 | 记忆存取 |
| `ai/recall.ts` | 静默向量召回（事实 + 事件卡片） | 检索 |
| `ai/embeddings.ts` | 向量客户端（多账号池 failover） | 向量 |
| `ai/chatLog.ts` | AI 侧聊天记录读取与压缩 | 日志读 |
| `ai/sessionSummary.ts` | 会话滚动摘要（窗口外压缩） | 摘要 |
| `ai/extractor.ts` | 攒够 N 条触发事实提取 | 记忆提取 |
| `ai/nightly.ts` | 每日维护管线（5 步幂等） | 夜间 |
| `ai/dailyContent.ts` | 用户可见的每日日记 + 推荐 | 内容 |
| `ai/tasksContext.ts` | 当前提醒/备忘列表注入 | 任务 |
| `ai/actionService.ts` | AI actions 解析/确认/执行（建提醒备忘等） | Actions |
| `ai/conflictDetector.ts` | 后台冲突检测 + 主动介入 | 冲突 |
| `ai/interjector.ts` | 后台主动插话 | 插话 |
| `ai/reminderScheduler.ts` | 到点提醒 Bark 推送扫描 | 提醒 |
| `ai/trace.ts` | 全链路 trace 日志 | 调试 |
| `ai/params.ts` | maxTokens/温度/阈值/节奏 调参中心 | 参数 |
| `ai/time.ts` | 北京时间工具（作息日早 6 点切日） | 时间 |

---

## 二、入口分流（aiService.ts）

`handleUserMessage(io, user, message)` 是 AI 流水线的唯一入口，由 `socket/realtime.ts` 在 `message:send` 后 fire-and-forget 调用。

### 2.1 分流逻辑

```
收到真人消息（kind === "user"）
  │
  ├─ 非文本且非图片 → return（不处理）
  │
  ├─ aiEnabled() = false（未配 AI_*）
  │   ├─ couple 频道 → return（不插话）
  │   └─ ai 私聊   → 发本地兜底回复（4 句随机），550ms 延迟模拟打字
  │
  ├─ couple 频道（storedChannel === "couple"）
  │   ├─ 非文本 → return（couple 暂不处理图片召唤）
  │   ├─ onCoupleUserMessage() → 攒够 8 条触发事实提取
  │   ├─ maybeCheckConflict()  → 后台冲突检测（fire-and-forget）
  │   ├─ maybeInterject()      → 后台主动插话（fire-and-forget）
  │   └─ 含 @大橘？
  │       ├─ 是 → queueRespond（串行队列应答）
  │       └─ 否 → 不答
  │
  └─ ai 私聊频道（storedChannel === "ai:<username>"）
      └─ queueRespond（每条文本/图片都答，不需要召唤）
```

### 2.2 滚动摘要

收到真人消息后，无论要不要回答，都会 `maybeUpdateSummary(storedChannel)` 推进一次滚动摘要更新（阈值不够早退，近乎零成本）。这样不 `@大橘` 地正常聊天也能推进摘要。

### 2.3 ReplySink

`makeSink(io)` 返回一个 `ReplySink`，封装了「发一条大橘消息」和「打字指示器」两个能力：

```typescript
interface ReplySink {
  emit(storedChannel, text, isFirst, meta?): Promise<void>;
  typing(storedChannel, value): void;
}
```

- `emit` → `createAiMessage(storedChannel, text, meta)` 入库 → socket 广播 `message:new` → couple 频道第一条触发 Bark 推送给不在线的一方
- `meta` 仅传给最后一条回复，承载 actions 确认卡 / 搜索来源卡片
- `typing` → ai 私聊频道发 `ai:typing` 事件；couple 频道不发（避免错误点亮私聊气泡）

---

## 三、意图判断 + 独立检索词生成（intent.ts）

两个 LLM 调用**并行**跑（`Promise.all`），输入相同（question + recent），互不依赖：

### 3.1 classifyIntent（意图判断）

**profile**: `"task"`（轻量、低温 0.2、maxTokens 500、超时 15s）

输出 `PlanContext` JSON：

| 字段 | 类型 | 含义 |
|---|---|---|
| `intent` | string | 意图分类（当前全部归 "chat"，保留字段供扩展） |
| `confidence` | number | 0~1 置信度 |
| `needSearch` | bool | 需要联网查实时/最新信息 |
| `needMemory` | bool | 需要长期事实记忆辅助 |
| `needShortMemory` | bool | 需要最近一周近况叙事 |
| `needRetrieval` | bool | 需要检索更早历史 |
| `needTasks` | bool | 问到提醒/备忘 |
| `needPetStatus` | bool | 问到大橘自己的状态（目前无真实数据源） |
| `needImages` | bool | 需要看最近一张图片 |
| `needClarification` | bool | 问题模糊，应先反问 |
| `retrievalQuery` | string | 检索词（intent 自己也生成一份，但有独立检索词时会被覆盖） |
| `resolvedQuestion` | string | 指代消解后的问题 |

**失败兜底**：模型没配/超时/JSON 解析失败 → 退回安全默认值（记忆检索照常开 `needMemory=true`，新增能力全关），绝不已读不回。

### 3.2 generateRetrievalQuery（独立检索词生成）

**profile**: `"task"`（maxTokens 450、超低温 0.05、超时 15s）

这是从旧后端 `buildRetrievalQuerySystem` 移植的专门 prompt，目标是把用户的口语问题转成适合向量检索的关键词包。

**核心规则**：
- 区分「交互壳」（"大橘你知不知道"）和「检索本体」（"林一 小偲发小"）
- 指代消解："你妈的发小" + 上下文提到"林一" → 输出 "林一 发小"
- 禁止泛词：相关/更多/其他/片段/线索/背景/关系/回忆/记忆/知道/询问
- 追问"还有更多吗"时只保留主对象，不加新面向
- prompt 里有 6 个好/坏例子实战打磨

**输出**：`{retrievalQuery, resolvedQuestion}`

### 3.3 检索词优先级

在 `replyEngine.respond()` 里：

```typescript
const query =
  (retrievalPlan && retrievalPlan.retrievalQuery) ||  // 独立检索词（最优先）
  plan.retrievalQuery ||                               // intent 自带
  retrievalQuery(effective, recent);                   // 原文拼接兜底
```

独立检索词那轮失败（`.catch(() => null)`）不影响主流程，退回 intent 自带或原文拼接。

---

## 四、应答主流程（replyEngine.ts）

### 4.1 串行队列

`queueRespond(trigger, sink)` 按频道串行排队：

```
queues: Map<storedChannel, { chain: Promise, pending: number, deferred: QueueItem | null }>
```

- 连环 `@大橘` 时不并发（防上游限流），逐条回答
- 积压 ≥ `PACE.queuePendingMax`（默认 3）时合并为最新请求；现有队列排空后仍会回答，不再静默丢弃
- 每轮有 `PACE.respondTimeoutMs`（默认 120s）兜底超时：发出可见反馈、释放队列，并禁止旧任务稍后乱序写回
- `respond()` 内部异常、模型连续空响应、AI 配置临时缺失也都有用户可见的本地兜底

### 4.2 respond() 完整流程

```
respond(trigger, sink):
  1. sink.typing(true)
  2. traceBegin()
  3. recent = recentMessages(channel, 30)，按 messageId 排除当前消息，避免提示词重复
  4. [plan, retrievalPlan] = Promise.all([
       classifyIntent(question, recent),
       generateRetrievalQuery(question, recent).catch(() => null),
     ])
  5. effective.question = plan.resolvedQuestion || question
  6. query = retrievalPlan?.retrievalQuery || plan.retrievalQuery || 原文拼接
  7. [recalled, mood, imageContext, searchResult] = Promise.all([
       (needMemory || needRetrieval) ? recallSafe(query, channel) : NO_RECALL,
       ensureDailyMood().catch(""),
       describeLatestImageIfNeeded(plan, recent, trigger),
       needSearch ? webSearch(query, GEN.search) : null,
     ])
  8. tasksText = needTasks ? tasksTextRich().catch("") : ""
  9. out = chat({ profile:"chat", system: buildSystem(...), user: buildUser(...), gen: GEN.reply })
  10. replies = normalizeReplies(out)
      → 空则原样重试一次
      → 仍空则固定兜底 "呜…我刚脑子卡了一下喵"
  11. actions = parseActions(out)  →  打包成 confirmMeta
  12. searchMeta = searchResult?.annotations（来源卡片）
  13. 逐条 emit：
      for i in 0..replies.length:
        if i > 0: sleep(900~1600ms)
        isLast = (i == replies.length - 1)
        sink.emit(channel, replies[i], i==0, isLast ? finalMeta : null)
  14. traceFlush()
  15. sink.typing(false)
```

### 4.3 上下文组装

**两层设计**（缓存友好）：

**system**（一天内基本不变，Claude 系吃提示词缓存）：
```
personaCore(names)                       ← 人设（身份+性格+记忆姿态+语气）
频道区分（私聊 vs 共享）
【人物卡】profileCardsText()              ← needMemory 时才带，避免普通闲聊被画像淹没
【短期记忆】getDoc("short-term")          ← needShortMemory 时才带
【今日心情】mood
【澄清提示】                               ← needClarification 时加一句
【记忆怎么用】                             ← 自然带出、不念档案、不加戏
【不确定就澄清】                           ← 指代不明先反问
【上下文证据优先级】                       ← 当前请求优先，人物卡不当心理诊断
【像人发微信一样说话】                     ← 1~3 条，第一条必须有实际信息
【任务 actions 规则】                      ← 仅 needTasks=true 时注入，含时间换算与确认卡机制
【输出格式】                               ← JSON {replies, actions}
```

**user**（每次都变）：
```
现在是 YYYY-MM-DD HH:mm（北京时间）
【前情摘要】summaryText(channel)           ← 滚动摘要
【更早背景】recent 前 22 条
【紧邻上文】recent 后 8 条
【相关记忆（长期事实）】recalled.factsContext
【相关记忆（过往事件）】recalled.episodesContext
【你刚看了一眼最近的图片】imageContext    ← needImages 时
【提醒/备忘概况】tasksText                ← needTasks 时（带 id+标题明细）
【联网查到的信息】searchResult.content    ← needSearch 时
（needSearch 但没查到 → 提示如实说查不到）
{requesterName} 对你说：{question}
请以大橘的身份回复。
```

---

## 五、记忆系统

### 5.1 三张表

| 表 | 存什么 | 向量 |
|---|---|---|
| `ai_facts` | 长期事实（偏好/雷区/纪念日/约定等），一行一条 | 有 embedding BLOB |
| `ai_episodes` | 事件卡片（每天按话题切卡，title/summary/keyPoints/mood/conclusion） | 有 embedding BLOB |
| `ai_docs` | KV 文档：人物卡/关系卡/短期记忆/日记/心情/滚动摘要/任务完成标记 | 无（纯文本） |

**注意**：旧后端有第三层 `chunk_embeddings`（39228 条原始聊天分段向量），新架构**已废弃**——`ai_episodes` 事件卡片已是对它的浓缩总结，再加一层是倒退。

### 5.2 静默召回（recall.ts）

每次应答都跑（不再只限"你记得吗"类问题）：

```
recall(query, storedChannel):
  vector = embedOne(query)
  facts = listFacts().map(score = similarity(vector, f.vector))
          .filter(score >= 0.45).sort(desc).slice(0, 8)
  episodes = [listEpisodes("couple"), (私聊时) listEpisodes("ai:<user>")]
              .map(score).filter(>= 0.4).sort(desc).slice(0, 6)
  return { factsContext, episodesContext }
```

- 前 3 张高分事件卡带 keyPoints 和 conclusion（卡片里最值钱的因果细节），其余只给标题行控制 token
- 无向量服务时退化为「高重要度事实兜底」（importance ≥ 4），保证雷区/纪念日这类底牌仍然在场
- 记忆主体永远查 couple 的事件卡；私聊额外查本人私聊卡片，但私聊卡片绝不进 couple 的回答

### 5.3 事实提取（extractor.ts）

couple 频道每攒 `PACE.factScanEveryMessages`（默认 8）条用户文本消息触发一次：

- 拉取自上次游标以来的消息（max 200 条）
- 把当前所有 `fresh` 事实作为去重参考喂给 LLM
- LLM 输出新事实 JSON 数组（subject/category/text/importance）
- `addFact()` 内部做 embedding 查重（相似 ≥ 0.9 只刷新 `last_seen_at`，不重复入库）
- 新事实入库时 `status = "fresh"`，等夜间收口转正

首次启动时游标初始化为"现在"（不回扫历史），历史事实靠 nightly 补。

### 5.4 每日维护管线（nightly.ts）

北京时间早 6 点（`DAY_ROLLOVER_HOUR`）切日后跑，每分钟检查一次。5 步**独立完成标记**（`done:<step>:<date>`），失败互不拖累、重启/隔天自动补跑，全程幂等。

```
1. generateDigest(date)
   昨天 couple 聊天 → markdown 日记（存 ai_docs[done:digest:<date>]）
   内部素材，不展示给用户

2. generateEpisodes(channel, date)
   对 couple + 每个 ai:<user>：
   昨天聊天按话题切 3~12 张事件卡
   先删该日期旧卡，再插新卡（带 embedding）
   存 ai_episodes 表

3. consolidateFacts(date)
   对每条 fresh 事实：
   算与 active 事实的相似度（阈值 0.7）
   LLM 裁决 keep / merge <id> / discard
   未处理的 fresh 默认转 active（宁可多记）
   
4. rewriteShortTerm(date)
   前 3 天 digest + 旧 short-term + 120 条 active 事实
   → LLM 重写「大橘短期记忆」markdown
   存 ai_docs["short-term"]
   有 shrink 保护：新内容 < 旧 34% 且旧 > 400 字时拒绝覆盖
   硬截 3800 字

5. refreshProfileCards(date)
   curated 事实（boundary 类 + importance≥4）+ short-term + recent digest
   → LLM 写 2 张人物卡 + 1 张关系卡
   存 ai_docs["profile:<username>"] / "relationship"
   每张 ≤ 1500 字
```

另外导出 `ensureDailyMood()`：懒生成今日心情一句话，缓存 `ai_docs["mood:<date>"]`，失败有 5 句固定兜底。

### 5.5 会话滚动摘要（sessionSummary.ts）

解决「聊得久了忘掉窗口外内容」：

- 窗口 = `CONTEXT.recentCount`（默认 30 条）
- 窗口外的消息既不在最近聊天里、也还没进当晚事件卡索引
- 收到真人消息后 `maybeUpdate(channel)`：窗口外新积累 ≥ `sessionSummaryUpdateEvery`（默认 14）条时，LLM 把旧摘要 + 新消息合并重写
- 存 `ai_docs["session-summary:<channel>"]`，JSON `{text, upToTs}`
- 应答时 `summaryText(channel)` 读缓存零开销，截断到 1000 字
- 每频道有 `updating` Set 互斥锁

---

## 六、Actions 系统（actionService.ts）

让大橘能帮主人建提醒/备忘、完成/删除已有项。**不会立刻生效**，先以「确认卡」挂在 AI 消息的 `meta_json` 上展示，主人点确认后才真正写入 `personal_items` 表。

### 6.1 支持的 action 类型

| type | 说明 | 关键字段 |
|---|---|---|
| `add_reminder` | 建提醒 | title, time("YYYY-MM-DD HH:mm"), ownerName? |
| `add_memo` | 建备忘 | text(Markdown), ownerName? |
| `complete_reminder` | 完成提醒 | id 或 text 关键词 |
| `delete_reminder` | 删除提醒 | id 或 text 关键词 |
| `edit_memo` | 修改备忘 | id 或 text 关键词, newText |

### 6.2 流程

```
AI 回复 JSON: {replies:[...], actions:[{type:"add_reminder",...}]}
  ↓ replyEngine.parseActions(out)
  ↓ describeAction(action) → 生成 label（如 "提醒：吃药 · 2026-07-09 08:00"）
  ↓ 打包成 ConfirmMeta { confirm: { status:"pending", items:[...], requesterName, requesterUsername } }
  ↓ 挂在最后一条回复的 meta_json 上
  ↓ sink.emit → createAiMessage(channel, text, meta) → message:new 广播
  ↓
iOS 收到消息，渲染确认卡（确认/取消按钮）
  ↓ 用户点确认
iOS emit "action:confirm" { messageId, decision:"confirm"|"cancel" }
  ↓ socket/realtime.ts 收到 → confirmAction(io, messageId, decision)
  ↓
confirmAction:
  读 message.meta_json → 解析 ConfirmMeta
  ├─ decision="cancel" → status="cancelled" → 写回 → emit "message:update"
  └─ decision="confirm" → 逐条 applyAction(item.action, {requesterUsername})
       ├─ add_reminder → createPersonalItem({kind:"reminder", title, dueAt, scope:"shared"})
       ├─ add_memo     → createPersonalItem({kind:"memo", title, bodyMarkdown, scope:"shared"})
       ├─ complete_reminder → updatePersonalItem(id, {isDone:true})
       ├─ delete_reminder   → deletePersonalItem(id)
       └─ edit_memo         → updatePersonalItem(id, {title, bodyMarkdown})
     → status="confirmed", failed=N → 写回 → emit "message:update"
```

### 6.3 时间换算

`parseReminderTime(time)` 把模型给的字符串归一成毫秒时间戳：

- `"YYYY-MM-DD HH:mm"` → 当作北京时间，减 8 小时得到 UTC 毫秒
- `"HH:mm"` → 今天的该时刻
- 纯数字 → 直接当毫秒戳

### 6.4 id vs text 关键词

完成/删除/修改时优先用 `id`（system prompt 里告诉模型「下面【当前未完成的提醒】里带了 id 就优先填 id」）；只有确实拿不到 id 时才退回 `text` 关键词匹配，关键词要抄原文里一段连续出现的短语，不要改写、缩写或加标点。

### 6.5 tasksTextRich（任务上下文注入）

`needTasks` 命中时，`tasksTextRich()` 返回当前提醒/备忘的明细列表（不是只给计数）：

```
【当前未完成的提醒】（执行 complete_reminder/delete_reminder 时优先填 id）
- id:abc123 「吃药」 · 2026-07-09 08:00
- id:def456 「买牛奶」

【当前备忘录】（执行 edit_memo/delete_memo 时优先填 id）
- id:ghi789 周末旅行计划
```

让模型执行 complete/delete/edit 时能精准定位，不会闭着眼睛猜 id。

---

## 七、联网搜索（provider.ts webSearch）

复用 `AI_VISION_*` 配置的 MiMo 账号（同一个账号既能识图也能联网）。

### 7.1 协议

MiMo 私有的 `tools:[{type:"web_search", max_keyword:3, force_search:true, limit:3}]` 格式，**不是**通用 OpenAI `tools` / `enable_search` 那一套。

文档：https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/text-generation/tool-calling/web-search

### 7.2 返回值

```typescript
interface SearchResult {
  content: string;          // 搜索后的回答正文
  annotations: Citation[];  // 来源引用列表
}
interface Citation {
  url: string;
  title: string;
  site_name?: string;
  summary?: string;
}
```

`annotations` 是 MiMo 在 `choices` 之外返回的结构化来源列表，前端展示为来源卡片。

### 7.3 在 respond() 里的使用

- `needSearch` 命中 → `webSearch(query, GEN.search)` 并行跑
- `searchResult.content` 注入 `buildUser()` 的【联网查到的信息】段落
- `searchResult.annotations` 打包成 `{search: {items, ts}}` meta，挂在最后一条回复上
- iOS 端 `SearchCitationsCard` 渲染来源链接列表
- 没查到（`content` 为空且 `annotations` 为空）→ system prompt 里已指示「如实告诉对方查不到，不要编造内容」

### 7.4 maxTokens 注意

MiMo 是推理模型，`max_tokens` 太小会在看不见的 `reasoning_content` 阶段就被截断，可见 `content` 永远是空的。`GEN.search` 已调到 1800，别调小。

测试时不要用 Wikipedia/httpbin.org 这类不稳定公网地址，MiMo 服务端自己去抓会失败，会误以为是集成 bug。

---

## 八、图片识别（provider.ts describeImage）

OpenAI 兼容的多模态 `image_url` 格式：

```typescript
messages: [{
  role: "user",
  content: [
    { type: "text", text: "用一两句话简短描述这张图片的内容，中文回答。" },
    { type: "image_url", image_url: { url: imageUrl } },
  ],
}]
```

### 8.1 触发逻辑

- `classifyIntent` 输出 `needImages=true` 时才识图（intent prompt 里有规则：只有最近真有图片、且这次请求确实和那张图有关才设 true）
- `describeLatestImageIfNeeded(plan, recent)` 找最近一张图片消息，调 `describeImage(url)`
- 结果以纯文本注入 `buildUser()` 的【你刚看了一眼最近的图片】段落：`"{senderName}发的图片，内容大致是：{description}"`
- ai 私聊每条图片都识图；couple 频道只有意图判断认为"需要看图"时才回看最近一张

### 8.2 maxTokens

`GEN.describeImage = 1500`。同样是 MiMo 推理模型，别调小，否则 `reasoning_content` 阶段截断、`content` 为空。

---

## 九、冲突检测（conflictDetector.ts）

couple 频道收到真人消息时后台跑（fire-and-forget，不经 @召唤）。检测到吵架迹象 → 主动发一条介入消息。

### 9.1 安全设计

| 门控 | 值 | 说明 |
|---|---|---|
| ≥2 条用户消息 | — | 防单条误判 |
| ≥2 个不同发送者 | — | 防自言自语误判 |
| 距上次检测 ≥3 条新消息 | `MIN_NEW_MESSAGES` | 增量门控，避免每条都跑 |
| 上次介入后 15 分钟冷却 | `SPEAK_SILENCE_MS` | 防轰炸 |
| 置信度阈值 | 0.7 | `CONFLICT_THRESHOLD`，宁可漏判不要误判 |
| 互斥锁 | `running` | 防并发 |

### 9.2 LLM 调用

- profile: `"task"`，maxTokens 1400，temperature 0.25
- system prompt 移植自旧后端 `assessConflictAndReply`，包含：
  - 哪些算冲突信号（情绪降温/阴阳怪气/攻击翻旧账/比较打压/冷暴力/单方面爆发）
  - 哪些不算（正常分歧/撒娇抱怨/一起吐槽第三方/单纯在忙）
  - 先分析再下结论（reason 字段必须真分析 A/B 各自在意什么、深层原因）
  - 宁可漏判不要误判
  - reply 要求短/具体/可跳过，禁止"别吵啦/抱一抱/和好吧"这类空话
- 输出 `{conflict, confidence, reason, reply}`

### 9.3 介入

`conflict=true && confidence≥0.7 && reply 非空` → `createAiMessage("couple", reply)` → `message:new` 广播 + Bark 推送。更新 `lastConflictTs`。

---

## 十、主动插话（interjector.ts）

couple 频道攒够一定量真人消息后，后台判断「大橘现在有没有话想说」。没有就安静，绝不为存在感硬找话题。

### 10.1 节奏

| 参数 | 值 | 说明 |
|---|---|---|
| `INTERJECT_EVERY` | 8 | 攒够 8 条真人消息考虑一次 |
| `COOLDOWN_MS` | 2 小时 | 距上次插话冷却 |
| `CONTEXT_LINES` | 20 | 拉多少条最近聊天 |

### 10.2 LLM 调用

- profile: `"task"`，maxTokens 900，temperature 0.8（高温保 spontaneity）
- system prompt 移植自旧后端 `interject`，核心规则：
  - 有话想说才开口，不是定时巡逻找话题的客服
  - 纠正/提醒（他们忘了什么你记得的事）
  - 被"秀到"的真实反应（"真受不了你们俩了"）
  - 接住被忽略的小情绪
  - `shouldReply:false` 就安静
- 上下文：最近聊天 + 召回记忆 + 今日心情（精简版，不带 plan/intent）

### 10.3 发出

`shouldReply=true && reply 非空` → `sleep(700~1400ms)` 模拟打字延迟 → `createAiMessage("couple", reply)` → 广播 + 推送。更新 `lastInterjectTs`、重置 `msgCount`。

---

## 十一、到点提醒扫描（reminderScheduler.ts）

定时扫 `personal_items` 表，把到点的未完成提醒推送给主人（Bark）。

### 11.1 设计

- 每 60 秒扫一次
- 查询：`kind='reminder' AND is_done=0 AND due_at > lastScanTs AND due_at <= now`
- 内存里记 `lastScanTs` 游标，启动时初始化为「现在」——不回推服务挂掉之前攒下的旧提醒
- 对每条到期提醒：查 owner 的 `bark_key` → `sendBarkPush(barkKey, "大橘提醒你", "{title} · {HH:mm}")`
- 互斥锁 `running` 防并发

### 11.2 启动

在 `server.ts` 里 `registerRealtime(io)` 之后 `startReminderScheduler(io)`。需要 io 是因为以后可能扩展到在 couple 频道插一条到点播报消息。

---

## 十二、Reply Trace 全链路日志（trace.ts）

每轮 `respond()` 创建一个 trace，各步往里堆，`finally` 时 flush 到 `.data/ai_logs/reply-trace-YYYYMMDD.log`（append）。

### 12.1 记录的内容

```typescript
interface TraceEntry {
  ts, channel, requesterName, question;
  intent?: PlanContext;           // 意图判断结果
  retrievalPlan?: RetrievalPlan;  // 独立检索词
  retrieval?: { query, rawFacts, rawEpisodes, factMinScore, episodeMinScore };
  context?: { profileCards, mood, shortMemory, factsContext, episodesContext, imageContext, searchContext, tasksText, sessionSummary, recentEarlier, recentImmediate };
  reply?: { stage, usedVision, wantsSearch, replies, actions };
  conflict?: { conflict, confidence, reason, reply };
  interject?: { shouldReply, reply };
  error?: string;
}
```

### 12.2 用途

排查「这轮回复为什么这么答/为什么没记忆」时直接看这个文件。每条 trace 以 `─────` 分隔，含时间戳、频道、提问者、问题原文，后面是完整 JSON。

---

## 十三、参数中心（params.ts）

所有 maxTokens / temperature / 阈值 / 超时 / 节奏全在这里。

### 13.1 GEN（各场景 LLM 调参）

| profile | maxTokens | temp | timeout | 用途 |
|---|---|---|---|---|
| `intent` | 500 | 0.2 | 15s | 意图判断 |
| `retrievalQuery` | 450 | 0.05 | 15s | 独立检索词生成 |
| `reply` | 2000 | 0.85 | 45s | 用户问答（直出 replies+actions JSON） |
| `extractFacts` | 900 | 0.2 | 30s | 后台事实提取 |
| `sessionSummary` | 900 | 0.3 | 20s | 会话滚动摘要 |
| `dailyDigest` | 2200 | 0.45 | 90s | 每日日记 |
| `episodes` | 4000 | 0.35 | 120s | 事件卡片切分 |
| `consolidateFacts` | 2000 | 0.2 | 90s | 夜间事实收口 |
| `shortTermRewrite` | 3400 | 0.35 | 90s | 短期记忆重写 |
| `profileCards` | 1600 | 0.4 | 90s | 人物卡×2+关系卡 |
| `dailyMood` | 200 | 0.9 | 20s | 今日心情 |
| `describeImage` | 1500 | 0.4 | 40s | 图片识图（MiMo 推理模型，别调小） |
| `search` | 1800 | 0.3 | 45s | 联网搜索（同上） |
| `conflict` | 1400 | 0.25 | 30s | 冲突检测 |
| `interject` | 900 | 0.8 | 20s | 主动插话 |

### 13.2 MEMORY（记忆检索阈值）

| 参数 | 值 | 说明 |
|---|---|---|
| `factTopK` | 8 | 事实注入上限 |
| `factMinScore` | 0.45 | 事实相似度阈值（低于不带） |
| `episodeTopK` | 6 | 事件卡片注入上限 |
| `episodeMinScore` | 0.4 | 事件卡片相似度阈值 |
| `factDupScore` | 0.9 | 新事实入库查重阈值 |
| `factTextMin/Max` | 3/200 | 事实正文长度限制 |
| `importantFactMin` | 4 | 高重要度事实兜底（无 embedding 时） |
| `shortTermMax` | 4200 | 短期记忆注入截断 |

### 13.3 CONTEXT（上下文窗口）

| 参数 | 值 | 说明 |
|---|---|---|
| `recentCount` | 30 | 应答时带多少条最近聊天 |
| `immediateCount` | 8 | 最后 N 条标为「紧邻上文」重点看 |
| `retrievalRecentUserLines` | 3 | 检索词拼接用最近几条用户消息 |
| `sessionSummaryUpdateEvery` | 14 | 窗口外攒够 N 条更新摘要 |
| `sessionSummaryMaxChars` | 1000 | 摘要注入截断 |
| `lineMax` | 180 | 单条消息压缩行截断 |
| `taskReminderCount` | 20 | 任务上下文带多少条提醒 |
| `taskMemoCount` | 12 | 任务上下文带多少条备忘 |
| `taskMemoTextMax` | 200 | 备忘标题截断 |

### 13.4 PACE（节奏）

| 参数 | 值 | 说明 |
|---|---|---|
| `replyGapMinMs` | 900 | 多条回复间最小停顿 |
| `replyGapJitterMs` | 700 | 随机抖动 |
| `queuePendingMax` | 3 | 频道队列积压上限 |
| `respondTimeoutMs` | 120s | 单轮应答兜底超时 |
| `factScanEveryMessages` | 8 | 每多少条 couple 消息触发事实提取 |

### 13.5 DAY_ROLLOVER_HOUR

`6` —— 北京时间早 6 点切日。半夜聊天算「昨天」，符合两人真实作息。

---

## 十四、LLM 客户端（provider.ts）

### 14.1 双协议

根据 model 名自动选协议：
- `claude-` 开头 → Anthropic 原生 Messages API（system 标 `cache_control:ephemeral`，连续对话吃提示词缓存约 1/10 计费）
- 其他 → OpenAI 兼容 `/chat/completions`

### 14.2 模型分档

只分两档（对比旧后端 15 个 profile 大幅精简）：
- `chat` = 直面用户的对话回复（要快、要有人味）
- `task` = 后台任务（记忆提取/日记/卡片/收口/意图判断/检索词/冲突/插话，可以慢、要稳定输出 JSON）

只配 `AI_*` 时两档共用同一个模型；`AI_CHAT_*` / `AI_TASK_*` 可分别覆盖。

### 14.3 失败处理

所有调用失败/未配置一律返回 `null`，调用方自行兜底——用户永远不该看到堆栈。

`chat()` 有 `AbortController` 超时控制。

HTTP 失败会记录状态码、`Retry-After` 和最多 400 字的上游错误正文；成功但内容为空时记录 `finish_reason` / `stop_reason`，便于区分限流、截断和模型空响应。日志不记录请求 Authorization 头。

### 14.4 JSON 提取

`extractJson<T>(text)` 容忍：
- ` ```json ` 包裹
- 前后多余文字
- 截取第一个 `{` 到最后一个 `}`

`extractReplyText(text)` 是 JSON 解析失败时的兜底（通常是 maxTokens 截断）：正则抠出 replies 数组第一条。

---

## 十五、人格（persona.ts）

所有场景（问答/日记/记忆整理/插话/冲突）都引用这里，改性格只改这一个文件。

```
personaCore(names) = 身份行（含主人名）
  + "在这个家里，两位主人就是你的爸爸妈妈..."
  + TRAITS（4 条性格）
  + MEMORY_STANCE（3 条记忆姿态，含「不要给记忆加戏」）
  + VOICE（4 条语气）
```

具体行为规则（输出格式、actions 用法、搜索规则等）在各场景的 system prompt 里叠加，不在 persona 里。

---

## 十六、数据库表

AI 相关的 3 张表（schema 在 `db/index.ts`）：

### 16.1 ai_facts

```sql
CREATE TABLE ai_facts (
  id TEXT PRIMARY KEY,
  subject TEXT NOT NULL,        -- both / daju / <username>
  category TEXT NOT NULL,       -- profile/preference/habit/health/boundary/relationship/plan/event/observation
  text TEXT NOT NULL,
  importance INTEGER DEFAULT 3, -- 1~5
  status TEXT DEFAULT 'fresh',  -- fresh（白天新提取）→ active（夜间收口转正）
  embedding BLOB,               -- 向量
  created_at INTEGER,
  updated_at INTEGER,
  last_seen_at INTEGER          -- 命中查重时刷新，用于排序
);
```

### 16.2 ai_episodes

```sql
CREATE TABLE ai_episodes (
  id TEXT PRIMARY KEY,
  channel TEXT NOT NULL,        -- couple / ai:<username>
  date TEXT NOT NULL,           -- "YYYY-MM-DD"
  title TEXT,
  summary TEXT,
  key_points_json TEXT,         -- JSON 数组
  mood TEXT,
  conclusion TEXT,
  keywords TEXT,
  embedding BLOB,
  created_at INTEGER
);
```

### 16.3 ai_docs

```sql
CREATE TABLE ai_docs (
  key TEXT PRIMARY KEY,
  text TEXT,
  updated_at INTEGER
);
```

key 约定：
- `profile:<username>` / `relationship` — 人物卡/关系卡
- `short-term` — 短期记忆（近一周叙事）
- `mood:<date>` — 今日心情
- `digest:<date>` — 每日日记
- `session-summary:<channel>` — 会话滚动摘要
- `done:<job>:<date>` — 每日任务完成标记
- `cursor:<name>` — 游标（如 `cursor:fact-scan`）

---

## 十七、Socket 事件

AI 相关的 socket 事件（在 `socket/realtime.ts` 注册）：

| 事件 | 方向 | 说明 |
|---|---|---|
| `message:new` | S→C | 新消息（含 AI 回复），meta 字段携带确认卡/来源卡片 |
| `message:update` | S→C | 消息更新（确认/取消 action 后更新 meta） |
| `message:recalled` | S→C | 撤回 |
| `ai:typing` | S→C | AI 输入中（仅 ai 私聊频道） |
| `action:confirm` | C→S | 用户点确认/取消 `{messageId, decision:"confirm"\|"cancel"}` |
| `personalItem:changed` | S→C | shared 提醒/备忘变更（personal 不发） |

---

## 十八、iOS 端

### 18.1 数据模型（ChatMessage.swift 等）

`ChatMessage` 新增 `meta: ChatMessageMeta?` 字段：

```swift
struct ChatMessageMeta {
    var confirm: ActionConfirm?    // 确认卡
    var search: SearchMeta?        // 来源卡片
}

struct ActionConfirm {
    var status: String             // pending / confirmed / cancelled
    var items: [ConfirmItem]
    var requesterName: String
    var requesterUsername: String
    var failed: Int?
}

struct ConfirmItem: Identifiable {
    var action: AiAction
    var label: String
}

struct AiAction {
    var type: String               // add_reminder / add_memo / complete_reminder / delete_reminder / edit_memo
    var title, text, time, id, newText, ownerName, scope: String?
}

struct SearchMeta {
    var items: [SearchCitation]
    var ts: Int
}

struct SearchCitation: Identifiable {
    var url: String
    var title: String
    var siteName, summary: String?
}
```

### 18.2 ChatStore.swift

- `message:update` 事件 → `applyMessageUpdate(id, meta)` 更新对应消息的 meta 字段
- `confirmAction(messageId, decision)` → emit `action:confirm`

### 18.3 ChatView.swift

`MessageBubble` 主体在气泡内容下方渲染：

- `ActionConfirmCard`：pending 状态显示确认/取消按钮；confirmed/cancelled 显示状态标签
- `SearchCitationsCard`：来源链接列表，点击用 `Link` 打开

### 18.4 RemindersView.swift

已经接通真实 REST API（`store.fetchPersonalItems` / `createPersonalItem` / `updatePersonalItem` / `deletePersonalItem`），并监听 `personalItem:changed` socket 事件刷新。HANDOFF.md 里"占位数据"的说法已过时。

---

## 十九、环境变量

### 19.1 必需

```env
TOKEN_SECRET=固定的长随机字符串
COUPLECHAT_ACCOUNTS=xu|小旭|真实密码|🐶;si|小偲|真实密码|🐰
```

### 19.2 AI 对话

```env
AI_BASE_URL=https://api.deepseek.com/v1
AI_API_KEY=sk-xxx
AI_MODEL=deepseek-chat
AI_TRIGGER_ALIASES=@大橘
# AI_CHAT_* / AI_TASK_* 可分别覆盖对话模型和后台任务模型
```

### 19.3 识图 + 联网（同一个 MiMo 账号）

```env
AI_VISION_BASE_URL=https://api.xiaomimimo.com/v1
AI_VISION_API_KEY=sk-xxx
AI_VISION_MODEL=mimo-v2.5
```

MiMo 是推理模型，`max_tokens` 给太小会在 `reasoning_content` 阶段截断，可见 `content` 永远是空的。

### 19.4 向量检索（多账号池）

```env
# 多账号池写法（推荐）：key 逗号分隔，provider 内失败自动换下一个 key
EMBEDDING_MODEL=voyage-4
EMBEDDING_DIM=1024
EMBEDDING_VOYAGE_PROVIDER=voyage
EMBEDDING_VOYAGE_BASE_URL=https://api.voyageai.com/v1
EMBEDDING_VOYAGE_API_KEYS=pa-key1,pa-key2,...
EMBEDDING_MONGODB_PROVIDER=mongodb-voyage
EMBEDDING_MONGODB_BASE_URL=https://ai.mongodb.com/v1
EMBEDDING_MONGODB_API_KEYS=al-key1,al-key2,...

# 单 key 写法（兼容旧格式）：
EMBEDDING_BASE_URL=https://api.voyageai.com/v1
EMBEDDING_API_KEY=pa-xxx
EMBEDDING_MODEL=voyage-3.5-lite
EMBEDDING_DIM=1024
```

不配置时 ai 频道走本地兜底回复，recall 退化为高重要度事实兜底。

---

## 二十、调试指南

### 20.1 pm2 日志

```bash
tail -f /root/.pm2/logs/couplechat-server-out-0.log
```

关键日志行：

```
[ai] 大橘已就位（AI 模型已配置）
[ai] intent=chat 记忆=true 检索=false 看图=false 联网=true(命中) 任务=false 检索词="林一 发小"
[ai] 待确认 actions: add_reminder, add_memo
[ai] 联网搜索返回 3 条来源
[ai] 冲突介入 confidence=0.82 reason=...
[ai] 大橘主动插话：真受不了你们俩了
[reminder] 到点提醒扫描已启动（60s 间隔）
```

### 20.2 Reply Trace 日志

```bash
ls .data/ai_logs/reply-trace-*.log
```

每条 trace 含完整 intent、检索词、检索原始得分、上下文注入内容、最终回复、actions。排查"为什么这么答/为什么没记忆"直接看这个。

### 20.3 本地验证

```bash
curl http://127.0.0.1:8080/api/accounts   # 必须返回 xu, si
curl http://127.0.0.1:8080/health          # {ok:true}
```

配了 AI 的话日志里应该有一行 `[ai] 大橘已就位（AI 模型已配置）`。

### 20.4 测试 Actions

1. couple 频道发 `@大橘 提醒我明早9点吃药`
2. 大橘回复应带确认卡（"提醒：吃药 · 2026-07-09 09:00" + 确认/取消按钮）
3. 点确认 → 卡片变成"已确认" → `GET /api/me/items?kind=reminder` 能看到这条
4. 到点后 `reminderScheduler` 扫到 → Bark 推送"大橘提醒你：吃药 · 09:00"

### 20.5 测试冲突检测

1. 两人连续发几条带情绪的消息（阴阳怪气/翻旧账）
2. 攒够 3 条新消息 + 2 个发送者 + 冷却期已过
3. 看 pm2 日志 `[ai] 冲突介入 confidence=...`
4. couple 频道应出现一条大橘的介入消息

### 20.6 测试主动插话

1. 两人正常聊天（不 @大橘）攒够 8 条
2. 距上次插话 ≥2 小时
3. 大橘可能在 couple 频道自然插一句（也可能 `shouldReply:false` 安静）
4. 看 pm2 日志 `[ai] 大橘主动插话：...`

---

## 二十一、LLM 调用拓扑

```
普通 @大橘（2 轮，并行不增串行延迟）:
  classifyIntent ─┐
                  ├─ (Promise.all) → chat() → 发出回复+确认卡
  检索词生成 ─────┘

需要联网的 @大橘（同上，但 webSearch 并行跑）:
  classifyIntent ─┐
  检索词生成 ─────┤
                  ├─ (Promise.all) → chat() → 发出回复+来源卡
  webSearch ──────┤    ↑ content 注入上下文
  recall ─────────┤    ↑ annotations 挂 meta
  mood ───────────┘

couple 普通聊天（不 @大橘，fire-and-forget）:
  → conflictDetector.maybeCheck()   (独立 LLM)
  → interjector.maybeInterject()    (独立 LLM)

私聊大橘（同普通 @大橘）:
  classifyIntent ─┐
                  ├─ → chat() → 发出回复
  检索词生成 ─────┘
```

---

## 二十二、与旧后端（hugxu0/chat）的对比

| 维度 | 旧后端 | 新后端 |
|---|---|---|
| LLM 轮次 | 3 轮（plan + retrievalQuery + ask） | 2 轮（intent + retrievalQuery 并行 → reply） |
| 模型 profile | 15 个 | 2 档（chat / task） |
| 记忆层 | 3 层（facts + knowledge_cards + chunk_embeddings） | 2 层（ai_facts + ai_episodes，废弃 chunk_embeddings） |
| 存储 | markdown 文件 + SQLite | 纯 SQLite（ai_docs KV） |
| Actions | 12 种 | 5 种核心（add_reminder/add_memo/complete/delete/edit） |
| 联网搜索 | 两步（ask 输出 web_search action → askWithSearch） | 一步（intent 判断 → webSearch 并行 → 结果注入） |
| 冲突检测 | 有 | 有（移植） |
| 主动插话 | 有 | 有（移植） |
| 来源卡片 | 有 | 有 |
| Trace 日志 | 有（reply-trace-*.log） | 有（移植） |
| 人设 | persona.js | persona.ts（原样移植） |
| 到点提醒推送 | 无（旧后端 reminders 不带 Bark 扫描） | 有（reminderScheduler） |

人设本身完全保留；架构精简但能力追平甚至超越旧版。
