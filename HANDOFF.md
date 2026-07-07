# 悄悄话 · 原生 iOS 版 — 交接文档

> 最后更新：2026-07-07（当天内多次更新：语音消息、记录页改版、AI 意图判断/联网/识图、真实历史数据迁移到本地库、生产部署）
> 仓库：https://github.com/hugxu0/couplechat-ios
> 当前工作分支：`codex/new-backend-ios-media`
> 旧网页版/旧后端：https://github.com/hugxu0/chat（继续部署在 https://chat.huhuhu.top，服务器是另一台 RackNerd 主机 `23.254.222.199`，跟新后端完全无关，不要碰）
> 新原生后端：本仓库 `server/`（部署域名：https://hoo66.top，真实生产主机是 RFCHost 的 `82.40.34.107`，见第十节）

---

## 一、项目定位

这是双人私密聊天 App 的 SwiftUI 原生 iOS 版。旧项目是 Vue3 + Socket.IO 的 PWA，
部署在 `chat.huhuhu.top`。现在路线已经调整：**旧网站继续保留，原生 App 不再共用旧后端**。

当前原生 App 面向本仓库里的新后端：

```text
iOS App -> https://hoo66.top -> server/
旧网页/PWA -> https://chat.huhuhu.top -> hugxu0/chat
```

账号 username 必须长期固定：

```text
xu = 小旭
si = 小偲
```

不要再使用旧后端里的 `alice / bob`，否则聊天记录、已读、推送和 shared owner 都会乱。

开发机是 Windows，没有 Mac。本地不能直接编译 iOS；iOS 验证靠 GitHub Actions 生成未签名 ipa，
再用 iloader/SideStore 装到手机真机测试。

---

## 二、目录结构

```text
couplechat-ios/
├── project.yml
├── .github/workflows/build-ios.yml
├── HANDOFF.md
├── README.md
├── Sources/
│   ├── App/
│   │   ├── CoupleChatApp.swift
│   │   └── RootTabView.swift
│   ├── Core/
│   │   ├── Models.swift
│   │   ├── Keychain.swift
│   │   └── ChatStore.swift
│   ├── DesignSystem/
│   │   └── DS.swift
│   └── Features/
│       ├── Auth/LoginView.swift
│       ├── Chat/ChatHomeView.swift
│       ├── Chat/ChatView.swift
│       ├── Records/RecordsView.swift
│       ├── Pet/PetView.swift
│       ├── Reminders/RemindersView.swift
│       └── Profile/ProfileView.swift
└── server/
    ├── src/
    ├── docs/API.md
    ├── docs/DEPLOY.md
    ├── deploy/nginx-hoo66.top.conf
    ├── ecosystem.config.cjs
    ├── .env.example
    └── .env.production.example
```

### iOS 关键文件

| 文件 | 说明 |
|---|---|
| `Sources/Core/ChatStore.swift` | 登录、Socket、多频道消息、上传、已读、断线恢复、本地缓存、纪念日/统计聚合 |
| `Sources/Core/ChatLocalCache.swift` | 完整聊天记录本地落盘缓存（`Application Support/ChatCache/<username>.json`） |
| `Sources/Core/Models.swift` | `Account` / `Session` / `ChatMessage` / `ChatChannel` / `CoupleDates` / `AnniversaryEntry` |
| `Sources/Core/Keychain.swift` | 登录会话持久化；Keychain + UserDefaults 兜底 |
| `Sources/Features/Chat/ChatView.swift` | couple / ai 共用会话页；文字/图片/视频/语音气泡；按住说话录音；猫猫按钮=召唤大橘 |
| `Sources/Features/Chat/ChatHomeView.swift` | 聊天首页 |
| `Sources/Features/Records/RecordsView.swift` | 记录页：在一起大卡 + 自由增删的纪念日网格 + 本地聚合的聊天统计图（左右翻页） |
| `Sources/Features/Pet/PetView.swift` | 大橘 tab：宠物状态展示 + "和大橘聊聊"（进私聊 `channel: .ai`） |
| `Sources/Features/Profile/ProfileView.swift` | 我的页：连接状态、外观、日期设置（纪念日增删改在这里）、退出登录 |
| `Sources/DesignSystem/DS.swift` | 全局设计令牌 |

### 后端关键文件

| 文件 | 说明 |
|---|---|
| `server/src/server.ts` | 启动 Fastify + Socket.IO |
| `server/src/app.ts` | REST app、CORS、multipart、静态 uploads |
| `server/src/socket/realtime.ts` | Socket.IO 协议层 |
| `server/src/chat/messageService.ts` | 消息保存、历史、搜索、撤回、已读 |
| `server/src/auth/*` | 账号种子、密码哈希、token、REST 登录 |
| `server/src/upload/routes.ts` | 图片/视频/**音频**上传（`audio/m4a` 等已加入白名单，返回 `type: "voice"`） |
| `server/src/shared/sharedService.ts` | shared 键值状态（纪念日走这里，`anniversaries` key，见第五节） |
| `server/src/ai/aiService.ts` | AI 门面：入口分流、回复广播（未配模型时本地兜底） |
| `server/src/ai/intent.ts` | **意图判断**：一轮轻量 LLM 判断 needSearch/needMemory/needShortMemory/needRetrieval/needTasks/needPetStatus/needImages/needClarification |
| `server/src/ai/replyEngine.ts` | 应答引擎：先跑意图判断，再按需拉记忆/识图/联网/查任务，最后一轮 LLM 直出 1~3 条回复 |
| `server/src/ai/tasksContext.ts` | needTasks 命中时给"未完成提醒/备忘有几条"的概览 |
| `server/src/ai/embeddings.ts` | 向量客户端，支持**多账号池**（`EMBEDDING_<NAME>_PROVIDER/_API_KEYS`），失败自动换下一个 key/provider |
| `server/src/ai/provider.ts` | LLM 客户端：`chat()`（对话/任务）+ `describeImage()`（识图）+ `webSearch()`（联网，MiMo 私有 `tools:web_search` 格式） |
| `server/src/ai/memoryStore.ts` | 记忆存取：事实库 / 事件卡 / 文档 KV |
| `server/src/ai/nightly.ts` | 每日维护管线：日记→事件卡→事实收口→短期记忆→人物卡 |
| `server/src/ai/params.ts` | AI 调参中心（token/温度/阈值/节奏），含 `GEN.intent`/`GEN.describeImage`/`GEN.search` |
| `server/src/push/*` | Bark 推送基础能力 |

---

## 三、当前后端路线

新后端使用：

- Node.js + TypeScript
- Fastify
- Socket.IO v4
- SQLite via `sql.js`
- Bark 推送基础能力
- pm2 + nginx 部署

选择 `sql.js` 是为了避免 Windows/VPS 上 `better-sqlite3` 这类 native 模块编译问题。
当前体量只有两个人，够用；后续若要迁移到原生 SQLite/Postgres，service 层边界已经比较清楚。

### 生产环境变量

生产模板在 `server/.env.production.example`。

关键项：

```env
NODE_ENV=production
PORT=8080
HOST=127.0.0.1
PUBLIC_BASE_URL=https://hoo66.top
TOKEN_SECRET=固定的长随机字符串
COUPLECHAT_ACCOUNTS=xu|小旭|真实密码|🐶;si|小偲|真实密码|🐰
APP_DEEP_LINK_SCHEME=couplechat://
```

`TOKEN_SECRET` 必须长期固定。它一变，所有已登录 token 都会失效，用户会回到登录页。

首次成功启动并创建账号后，可以从服务器 `.env` 删除明文 `COUPLECHAT_ACCOUNTS`，已有账号不会被覆盖。

### AI（大橘）环境变量

不配置时 ai 频道走本地兜底回复。完整说明见 `server/.env.production.example`。

```env
AI_BASE_URL=https://api.deepseek.com/v1   # OpenAI 兼容口填到 /v1
AI_API_KEY=sk-xxx
AI_MODEL=deepseek-chat                    # claude- 开头自动走 Anthropic 原生协议
AI_TRIGGER_ALIASES=@大橘                   # couple 频道召唤词；ai 私聊每条都答
```

`AI_CHAT_*` / `AI_TASK_*` 可分别覆盖对话模型和后台任务模型。

**识图 + 联网搜索**（同一个 MiMo 账号，两种能力）：

```env
AI_VISION_BASE_URL=https://api.xiaomimimo.com/v1
AI_VISION_API_KEY=sk-xxx
AI_VISION_MODEL=mimo-v2.5
```

MiMo 是推理模型，`max_tokens` 给太小会在看不见的 `reasoning_content` 阶段就被截断，可见的
`content` 永远是空的（`GEN.describeImage`/`GEN.search` 已经调到够用的 1500/1800，别调小）。

联网搜索用的是 MiMo 私有的 `tools:[{type:"web_search",...}]` 格式（不是 OpenAI 通用
`tools`/`enable_search` 那一套），文档见
https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/text-generation/tool-calling/web-search 。
测试时不要用 Wikipedia/httpbin.org 这类地址——MiMo 服务端自己去抓图，这两个经常抓取失败或本身不稳定
（"failed to download url data" / 间歇 502），换一个稳定可达的公网图床/URL 再测，不要以为是集成 bug。

**向量检索（可选，支持多账号池）**：

```env
# 单 key 写法（兼容旧格式）：
EMBEDDING_BASE_URL=https://api.voyageai.com/v1
EMBEDDING_API_KEY=pa-xxx
EMBEDDING_MODEL=voyage-3.5-lite
EMBEDDING_DIM=1024

# 多账号池写法（推荐）：key 逗号分隔，provider 内失败自动换下一个 key，
# provider 之间也会顺序 failover。生产现在用的就是这套（Voyage 6 个 key + MongoDB AI Gateway 4 个 key）。
EMBEDDING_MODEL=voyage-4
EMBEDDING_DIM=1024
EMBEDDING_VOYAGE_PROVIDER=voyage
EMBEDDING_VOYAGE_BASE_URL=https://api.voyageai.com/v1
EMBEDDING_VOYAGE_API_KEYS=pa-key1,pa-key2,...
EMBEDDING_MONGODB_PROVIDER=mongodb-voyage
EMBEDDING_MONGODB_BASE_URL=https://ai.mongodb.com/v1
EMBEDDING_MONGODB_API_KEYS=al-key1,al-key2,...
```

### 部署

详细步骤见 `server/docs/DEPLOY.md`。**没有 CI/CD**，全靠手动 SSH 上服务器操作；本仓库没有部署
密钥/流水线，只能人肉执行下面的流程。

生产主机（RFCHost，`root@82.40.34.107`，本地 `~/.ssh/id_ed25519` 已经能直连，
`ssh -i ~/.ssh/id_ed25519 root@82.40.34.107`）：仓库已 clone 在 `/opt/couplechat-ios`，
PM2 进程名 `couplechat-server`。**部署前一定先备份**：

```bash
mkdir -p /root/codex-backups
cd /opt/couplechat-ios/server
tar -czf /root/codex-backups/couplechat-$(date +%Y%m%d-%H%M%S).tar.gz .data uploads .env
```

更新部署：

```bash
cd /opt/couplechat-ios
git pull origin codex/new-backend-ios-media
cd server
npm ci
npm run build
pm2 restart couplechat-server
```

nginx 示例：

```text
server/deploy/nginx-hoo66.top.conf
```

部署后必须验证：

```bash
curl http://127.0.0.1:8080/api/accounts   # 在服务器本机验证最快，不用等 DNS/nginx
```

`/api/accounts` 必须返回 `xu, si`。同时看 `pm2 list` 状态是不是 `online`，
`tail /root/.pm2/logs/couplechat-server-error-0.log` 有没有报错，
配了 AI 的话日志里应该有一行 `[ai] 大橘已就位（AI 模型已配置）`。

---

## 四、接口契约

完整契约见 `server/docs/API.md`。这里列核心部分。

### REST

| 接口 | 说明 |
|---|---|
| `GET /health` | 健康检查 |
| `GET /api/accounts` | 返回 `[{username,name,avatar}]` |
| `GET /api/me` | Bearer token 有效性核实（socket unauthorized 时的二次确认） |
| `GET /api/stats` | 聊天统计：近 10 天 + 近 12 月，按 username 分组计数（**iOS 记录页已经不用这个了**，改成本地聚合，见五、五点五节；接口本身没删） |
| `GET /api/daily` | 大橘日记（最近一篇）+ 今日推荐 |
| `POST /api/daily/recommend` | 「换一个」强制重新生成今日推荐 |
| `POST /api/login` | `{username,password}` -> `{token,username,name}` |
| `POST /api/upload` | multipart 单文件上传，Bearer token；mimetype 白名单含图片/视频/`audio/m4a` 等音频，返回的 `type` 字段会是 `image`/`video`/`voice` |
| `POST /api/me/push/bark` | 保存/清空 Bark key |

### Socket.IO

连接：

```js
io("https://hoo66.top", { auth: { token } })
```

客户端只使用逻辑频道：

```text
couple
ai
```

服务端内部把 AI 私聊存成 `ai:<username>`，两个人互不可见。

核心事件：

| 事件 | 方向 | 说明 |
|---|---|---|
| `message:send` | 客户端 -> 服务端 | 发文字/媒体，带 `channel` 和 `clientId` |
| `message:new` | 服务端 -> 客户端 | 新消息，含自己发出的回声 |
| `messages:fetch` | 客户端 -> 服务端 | 历史、补漏、上滑加载 |
| `messages:search` | 客户端 -> 服务端 | 服务端已有，iOS UI 未接 |
| `message:recall` | 客户端 -> 服务端 | 服务端已有，iOS UI 未接发起 |
| `read` | 客户端 -> 服务端 | 已读到某个 ts |
| `read:init` / `read:update` | 服务端 -> 客户端 | 已读状态 |
| `presence` | 服务端 -> 客户端 | 在线用户 |
| `away` | 客户端 -> 服务端 | 前后台状态 |
| `health` | 客户端 -> 服务端 | 回前台探测假连接 |
| `shared:init/update/set` | 双向 | shared 键值状态；`dates` key 存"在一起"日期，`anniversaries` key 存自由增删的纪念日/倒数日数组（`{items:[...]}`），完全是客户端约定的 JSON blob，服务端不关心结构 |
| `ai:typing` | 服务端 -> 客户端 | AI 输入中 |

---

## 五、iOS 当前能力

已完成：

- 登录页从 `hoo66.top/api/accounts` 拉账号
- 登录 session 持久化：Keychain + UserDefaults 备份
- 我的页显示连接状态，并有“退出登录”
- couple 频道文字收发
- ai 频道入口和会话页
- 后端 AI 系统（大橘）：应答引擎 + 记忆系统（事实库/事件卡/短期记忆/人物卡/每日维护），配好 `AI_*` 即生效；未配置时本地兜底
- 重连不再丢登录：token 走 connectParams 每次重连自带；unauthorized 先 REST 核实再登出
- 主题引擎：5 主题色 + 深浅模式（跟随系统/浅/深），全局 token 自适配（`Theme.swift` + `DS.swift`）
- 聊天壁纸：8 款预设渐变，couple/ai 独立设置，本机持久化
- 聊天搜索：会话页右上菜单 → 搜索（走 `messages:search`，关键词高亮）
- 记录页：在一起天数大卡（不变）+ 自由增删的纪念日/倒数日网格（只读展示，增删改在"我的→日期设置"）、
  聊天统计聚合自**本地缓存的完整聊天记录**（不再打 `/api/stats`），日/月切换、左右翻页看更早、点柱查看
- 我的页：身份卡（连接状态圆点）、外观设置、日期设置（纪念日/倒数日增删改统一在这里）、Bark 离线通知配置页
- 图片/视频选择、上传、发送
- **语音消息**：composer 麦克风按住说话录音（Telegram 式，左滑取消），松手发送，气泡内可播放；
  服务端 `/api/upload` 已放开 `audio/m4a` 等 mimetype 白名单
- composer 对称布局：附件/表情图标嵌进输入框左右两侧，麦克风/发送按钮统一主题色，跟猫猫按钮同一高度
- 猫猫按钮 = 在公共聊天里召唤大橘（自动插入 `@大橘 ` 触发词），私聊大橘走大橘 tab 的"和大橘聊聊"
- 本地聊天记录全量缓存（`ChatLocalCache.swift`），登录后先出本地缓存再补齐增量，离线也能看历史
- 图片气泡 `AsyncImage` 预览
- 视频气泡卡片展示
- 乐观发送、失败状态、文本失败重发
- 历史拉取、增量补漏、上滑加载更早
- 已读回执
- 在线状态
- 前后台 `away` + 回前台 `health`
- 新后端部署文档和 nginx/pm2 配置
- CI 出未签名 ipa
- 后端 AI 意图判断模块：联网搜索（MiMo）、识图（MiMo，私聊每条图都识别 / couple 频道靠意图判断按需识别）、
  多账号池向量检索（failover）、任务/备忘概况注入

未完成：

- `shared` 接到提醒/宠物页面（宠物/提醒页仍是占位数据）
- **`needPetStatus` 没有真实数据源**：意图判断能识别出"问到宠物状态"，但新架构服务端压根没存宠物状态
  （iOS 大橘 tab 是纯客户端展示），目前只能靠"今日心情"顶一部分，要做实需要专门加一套服务端状态存储
- couple 频道图片：只有当**后续文字消息** `@大橘` 触发、且意图判断认为"需要看图"时才会回看最近的图片；
  图片本身不能直接触发（没有配文字的入口），也不会在图片一发出来就自动识图
- 生产的旧聊天历史（老后端 `alice/bob` 的 387842 条消息 + 4331 张知识卡片 + 95 条事实）
  只导入了**本地开发库**，没有导入生产库——生产库现在是干净的（详见第十一节）
- Bark 通知点击 URL Scheme 打开指定页面
- 长按菜单：复制/回复/撤回
- 消息回复 UI
- 搜索结果点击跳转到消息位置（当前只展示结果列表）
- 视频播放预览
- 自定义相册壁纸（当前为预设渐变）
- 大橘 3D 模型
- 深色模式

---

## 五点五、后端 AI 架构（大橘）

从旧仓库 `hugxu0/chat` 移植并重构，核心精简，**2026-07-07 又把旧版的意图判断模块按需恢复了一部分**
（细节见旧库真实运行留下的 `data/ai_logs/reply-trace-*.log`，那是判断这套东西原貌的第一手证据）：

- **两档模型**：`chat`（对话）/ `task`（后台/意图判断），替代旧版 15 个 profile。
- **三张表**：`ai_facts`（长期事实+embedding）、`ai_episodes`（事件卡+embedding）、
  `ai_docs`（人物卡/短期记忆/日记/心情/摘要/游标，全 KV），不再有 markdown 文件。
- **缓存友好**：人设+人物卡+短期记忆+心情放 system（一天内不变，Claude 系可吃提示词缓存），
  每次变化的放 user。
- **意图判断（`ai/intent.ts`）**：应答前先跑一轮轻量 LLM 判断，输出 needSearch / needMemory /
  needShortMemory / needRetrieval / needTasks / needPetStatus / needImages / needClarification +
  指代消解后的问题 + 检索词，`replyEngine.respond()` 按这些标记有条件地去拉记忆/识图/联网/查任务，
  而不是像之前那样每次都全套跑一遍。判断这一步失败（模型没配/超时/JSON 解析失败）会退回安全默认值
  （记忆检索照常开，新能力都关），不会因为这一步崩了就答不出来。
- **识图（`ai/provider.ts` 的 `describeImage()`）**：OpenAI 兼容多模态 `image_url` 格式，
  走 `AI_VISION_*` 配置的 MiMo 账号。ai 私聊每条图片消息都会识图；couple 频道只有意图判断认为
  "需要看图"时才会回看 `recentMessages` 里最近一张图。
- **联网搜索（`ai/provider.ts` 的 `webSearch()`）**：同一个 MiMo 账号，私有 `tools:[{type:"web_search",...}]`
  格式（不是通用 OpenAI tool-calling），查不到就让模型如实说查不到，不编答案。
- **向量检索多账号池（`ai/embeddings.ts`）**：`EMBEDDING_<NAME>_PROVIDER/_BASE_URL/_API_KEYS`，
  一个 provider 一串 key，某个 key 失败自动换下一个，provider 之间也会顺序 failover；
  兼容旧的单 key 写法。

运行时链路：

```text
收到真人消息 → aiService.handleUserMessage
  ├─ couple：滚动摘要 tick + 每 8 条触发事实提取；含 @大橘 → 排队应答
  └─ ai 私聊：滚动摘要 tick + 每条文本/图片都排队应答
应答 = 意图判断(intent.ts, task 档)
     → 按需：静默召回(facts+episodes 向量检索) / 识图 / 联网搜索 / 任务概况
     → 上下文组装 → 1 轮 LLM(chat 档) → 1~3 条逐条发出
每日 06:00（北京）→ nightly 管线：日记 → 事件卡 → 事实收口 → 短期记忆重写 → 人物卡 → 心情
```

每步有独立完成标记（`ai_docs` 里 `done:<step>:<date>`），失败互不拖累、重启自动补跑。

调试时看 pm2 日志里的 `[ai] intent=... 记忆=... 检索=... 看图=...(命中) 联网=...(命中) 任务=...`
这行，能直接看出这轮回复实际用了哪些能力。

---

## 六、ChatStore 可靠性设计

改 `ChatStore.swift` 前先理解这些点：

1. **多频道存储**
   `messagesByChannel: [String: [ChatMessage]]`，当前支持 `.couple` 和 `.ai`。

2. **乐观发送**
   发消息时本地先插入 `pending`，id 使用 `clientId`。服务端 ack 或 `message:new` 回声后按真实 id / clientId 去重替换。

3. **失败处理**
   ack 超时或失败会标 `failed`。目前只有文字失败可点红叹号重发；媒体失败没有保留原始 Data，暂不自动重传。

4. **重连补漏**
   连接后，如果本地已有消息，按最后一条非 pending/failed 的 `ts` 做 `since` 增量拉取。

5. **假连接恢复**
   App 回前台时发 `health`，2.5s 超时就 disconnect + reconnect。

6. **登录持久化**
   `Keychain.saveSession` 同时写 Keychain 和 UserDefaults 备份，解决侧载环境下 Keychain 偶发不稳的问题。

7. **unauthorized**
   Socket 返回 unauthorized 会 `logout()`，清掉 session，用户回登录页。若频繁发生，优先检查服务器 `TOKEN_SECRET` 是否稳定。

---

## 七、构建与安装

GitHub Actions workflow：

```text
.github/workflows/build-ios.yml
```

手动触发：

```bash
gh workflow run "Build iOS IPA (unsigned)" --ref codex/new-backend-ios-media
gh run watch <run-id> --exit-status
```

构建产物：

```text
Artifact: couplechat-native-ipa
```

安装路线：

1. 下载 artifact zip。
2. 解压得到 ipa。
3. 用 iloader 导入 ipa。
4. iPhone 上信任开发者 / 保持开发者模式开启。

免费 Apple ID 签名 7 天过期，需要定期用 iloader 续签/重装。

---

## 八、测试清单

### 后端

```bash
curl https://hoo66.top/health
curl https://hoo66.top/api/accounts
```

确认 `/api/accounts` 是：

```text
xu, si
```

### App 基础

1. 安装最新版 ipa。
2. 用 `xu` 或 `si` 登录。
3. 我的页显示 `已连接 hoo66.top`。
4. 清后台再打开，不应回登录页。
5. 进入聊天，发送文字，无红叹号。
6. 退出登录按钮可用。

### 单手机验证收发

1. 用 `xu` 登录发一条消息。
2. 退出登录。
3. 用 `si` 登录。
4. 进入聊天，应能看到 `xu` 刚才发的消息。

实时双端验证需要第二台手机，或用命令行 Socket 客户端模拟另一个账号。

### 媒体

1. 点回形针选择图片。
2. 图片应出现上传中气泡，随后变成真实图。
3. 选视频应出现视频卡片。

### 语音

1. 按住麦克风按钮不放，出现录音条（红点+计时+"滑动取消"）。
2. 左滑超过阈值图标变垃圾桶，松手应该取消不发送。
3. 正常松手应该发送，气泡里能点开播放。
4. 服务器没配 `AI_VISION_*`/embedding 不影响语音收发，语音走的是 `/api/upload`，跟 AI 无关。

### AI（需要生产配好 `AI_*`/`AI_VISION_*`/`EMBEDDING_*`）

1. 公共聊天发 `@大橘 昨天吵架结果是啥`，应该有回复；发普通消息不带 `@大橘` 不应该有回复。
2. 点猫猫按钮，输入框应该自动填入 `@大橘 `，光标聚焦，不应该跳转页面。
3. 大橘 tab →"和大橘聊聊"，应该进独立私聊页，每条消息都会回。
4. 私聊发一张图，应该会识图（回复里能体现看到的内容）。
5. 问一个明显需要联网的问题（比如"现在几点"以外的实时信息），观察 pm2 日志
   `[ai] intent=... 联网=true(命中)`，回复应该带真实查到的信息，不是编的。
6. 记录页"聊天时光"卡片应该能左右滑动看更早的日子/月份，且是从本地缓存算出来的
   （断网也能看历史统计，只是看不到今天新消息）。

---

## 九、已知坑

- `chat.huhuhu.top` 是旧网站/旧后端，不要让原生 App 再指向它；它跑在另一台 RackNerd 主机
  （`23.254.222.199`）的 docker 容器里（image `chat-app`），跟新后端所在的 RFCHost 主机完全是两台机器，
  别搞混、别在错的机器上操作。
- 旧后端曾使用 `alice / bob`，新后端必须固定 `xu / si`。
- `TOKEN_SECRET` 不能每次部署都换，否则用户会反复回登录页。
- iOS 本地不能编译；Swift 编译错误只能靠 Actions 或 Mac/Xcode。
- `defaultScrollAnchor(.bottom)` 要求 iOS 17+，deployment target 不要降。
- 时间戳统一是毫秒，Swift 使用 `Double` 承接。
- 当前 `server/.data/`、`server/uploads/` 不入库，生产必须备份；本仓库没有 CI/CD，部署全靠手动 SSH。
- **本仓库根目录的 `data/` 是未跟踪目录**（在 `.gitignore` 之外，千万不要 `git add`）：里面是旧后端
  导出的真实私人聊天历史（`chat.db`，387842 条消息）、真实照片（`uploads/`）、AI 长期记忆文档。
  这是极其敏感的私人数据，绝对不能提交到 git、不能上传到任何第三方服务；已经导入过一份到
  **本地开发库**（`server/.data/couplechat.sqlite`），生产库没动，详见第十一节。
- MiMo（`AI_VISION_*`）是推理模型，`max_tokens` 太小会在 `reasoning_content` 阶段截断，
  可见回复是空的；测识图/联网别用 Wikipedia/httpbin.org 这类不稳定的公网地址，会误以为是 bug。
- 联网搜索走 MiMo 私有的 `tools:[{type:"web_search",...}]` 格式，别用通用 OpenAI `tools`/
  `enable_search` 参数去试，那些对 MiMo 无效。
- 本地开发库（`server/.data/couplechat.sqlite`）现在有真实历史数据（387842 条消息等），
  跑本地测试/写迁移脚本时注意别把它当成"空库"操作，也别把这个文件提交到 git。

---

## 十、账号和环境

| 东西 | 说明 |
|---|---|
| GitHub | `hugxu0`，本机 gh CLI 已登录 |
| iOS 签名 Apple ID | `gxhoo66@gmail.com`；她的手机用她自己的 Apple ID |
| 旧网站 | `https://chat.huhuhu.top`，保留给旧 PWA，服务器 `root@23.254.222.199`（RackNerd，本机 `~/.ssh/id_ed25519` 能连，公钥备注是 `racknerd`） |
| 新原生后端 | `https://hoo66.top`，服务器 `root@82.40.34.107`（RFCHost，hostname `iouWfaMJCWc.rfchost.com`，本机同一个 `~/.ssh/id_ed25519` 能连），仓库在 `/opt/couplechat-ios`，PM2 进程名 `couplechat-server` |
| 本地仓库 | `D:\Desktop\couplechat-ios` |
| 旧 PWA 仓库 | `D:\Desktop\chat` |
| AI provider | DeepSeek（对话，`deepseek-v4-pro`）、Xiaomi MiMo（识图+联网，`mimo-v2.5`）、Voyage + MongoDB AI Gateway（向量检索，多 key 池，见第三节） |

---

## 十一、旧后端历史数据迁移现状（2026-07-07）

用户把旧后端（`alice/bob`，`chat.huhuhu.top`）导出的真实数据放进了本仓库根目录 `data/`
（`chat.db` 908MB、387842 条消息、4331 张知识卡片、95 条长期事实、279 个上传文件、AI 记忆 markdown）。

**已经做的**：

- 用户名映射确认：`alice = xu(小旭)`，`bob = si(小偲)`，`ai = ai(大橘)`，`system = system`。
- `data/chat.db` 的 `messages` 表 → 本地开发库 `server/.data/couplechat.sqlite` 的 `messages` 表，
  字段做了改名/remap（`senderName`→`sender_name` 等），387842 条全部导入，用户名已改好。
- `data/chat.db` 的 `memory_facts` → 本地库 `ai_facts`（95 条，字段几乎一一对应，embedding 原样保留，
  `voyage-4`/`voyage-3.5-lite`，1024 维）。
- `data/chat.db` 的 `knowledge_cards` → 本地库 `ai_episodes`（4331 条，`body_markdown` 确认是
  `summary` 的重复文本，丢弃不损失信息）。
- `data/uploads/` 的 279 个文件 → `server/uploads/`，聊天记录引用到的 260 个不同 URL 全部对上号。
- 迁移前备份过 `server/.data/couplechat.sqlite.bak-pre-import`。

**没做的 / 故意跳过的**：

- `chunk_embeddings`（39228 条原始文本分段向量）**没有迁移**——新架构里根本没有对应的表，
  `ai/recall.ts` 只查 `ai_facts`/`ai_episodes` 的向量，不查原始分段，`knowledge_cards` 已经是对它的
  浓缩总结。如果以后真的需要这层细粒度检索，需要重新设计一张表，不是简单字段映射能解决的。
- `data/chat.db` 的 `shared` 表（`anniversaries`/`loveDate`/`memos`/`reminders`/`stickers` 等旧纪念日/
  提醒/表情包数据）**没有迁移**，用户当时只要求搬聊天记录。
- `daily_cache` 表（大部分是旧系统自己的幂等书签，比如 `kb-built:couple:2025-01-16`，跟新架构的
  游标机制不通用）**没有迁移**。
- **以上所有迁移只进了本地开发库，生产库（`82.40.34.107` 上的 `couplechat.sqlite`）完全没动**，
  现在是从 `xu/si` 干净起步的状态。如果要把这些历史数据也搬到线上，思路跟本地这次一样
  （用户名映射 + 字段改名 + 直接 `ATTACH DATABASE` 搬 `messages`/`ai_facts`/`ai_episodes`），
  但要在生产服务器上跑，跑之前必须先 `tar` 备份现有 `.data`/`uploads`。
