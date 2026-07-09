# 悄悄话 · 原生 iOS 版 — 交接文档

> 最后更新：2026-07-10（同步 Chat V2、贴纸、文件、头像与存储空间能力）
> 仓库：https://github.com/hugxu0/couplechat-ios
> 当前工作分支：`codex/chat-v2-uikit`
> 旧网页版/旧后端：https://github.com/hugxu0/chat（`https://chat.huhuhu.top`，RackNerd `23.254.222.199`，跟新后端无关）
> 新原生后端：本仓库 `server/`（`https://hoo66.top`，RFCHost `82.40.34.107`）

---

## 一、项目定位

双人私密聊天 App 的原生 iOS 版：SwiftUI 负责 App 壳、导航和大部分页面，Chat V2 会话核心使用 UIKit。旧项目是 Vue3 + Socket.IO 的 PWA。
**旧网站继续保留，原生 App 不再共用旧后端。**

```text
iOS App -> https://hoo66.top -> server/（PostgreSQL）
旧网页/PWA -> https://chat.huhuhu.top -> hugxu0/chat
```

账号 username 必须长期固定：

```text
xu = 小旭
si = 小偲
```

开发机是 Windows，没有 Mac。iOS 验证靠 GitHub Actions 生成未签名 ipa，再用 iloader/SideStore 装到真机。

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
│   │   ├── RootTabView.swift
│   │   └── AppNotificationDelegate.swift
│   ├── Core/
│   │   ├── Models.swift              # ServerConfig、数据模型
│   │   ├── Keychain.swift
│   │   ├── ChatStore.swift           # 数据中枢
│   │   ├── ChatLocalDatabase.swift   # 设备端 SQLite 缓存
│   │   ├── ChatLocalCache.swift      # 旧 JSON 缓存（仅迁移用）
│   │   ├── InteractionPayload.swift  # 互动特效解析与 overlay
│   │   ├── ReminderNotificationScheduler.swift
│   │   ├── ImageCache.swift          # 图片磁盘/内存缓存
│   │   ├── StickerStore.swift        # 本机贴纸库
│   │   └── EmojiCatalog.swift        # 表情面板 emoji 数据
│   ├── DesignSystem/
│   │   ├── DS.swift
│   │   └── Theme.swift
│   └── Features/
│       ├── Auth/LoginView.swift
│       ├── Chat/ChatHomeView.swift, ChatView.swift, ChatV2/, UIKit/
│       ├── Records/RecordsView.swift
│       ├── Pet/PetView.swift
│       ├── Reminders/RemindersView.swift
│       └── Profile/ProfileView.swift, ThemeStyleView.swift, StorageView.swift
└── server/
    ├── src/
    ├── docs/API.md, AI.md, DEPLOY.md, POSTGRES.md
    ├── deploy/nginx-hoo66.top.conf
    └── ecosystem.config.cjs
```

### iOS 关键文件

| 文件 | 说明 |
|---|---|
| `Sources/Core/ChatStore.swift` | 登录、Socket、多频道消息、上传、已读、断线恢复、REST CRUD、shared 状态 |
| `Sources/Core/ChatLocalDatabase.swift` | 设备端 SQLite：消息、已读、shared 状态；登录后先出本地再补增量 |
| `Sources/Core/ChatLocalCache.swift` | 旧 JSON 快照，一次性迁移到 SQLite |
| `Sources/Core/ImageCache.swift` | 全 App 图片缓存；存储空间页可统计/清理 |
| `Sources/Core/StickerStore.swift` + `EmojiCatalog.swift` | 本机贴纸库、分组/收藏、emoji 数据 |
| `Sources/Core/Models.swift` | `ServerConfig.baseURL = https://hoo66.top`；消息/提醒/纪念日模型 |
| `Sources/Features/Chat/ChatView.swift` | 会话入口，桥接到 Chat V2 |
| `Sources/Features/Chat/ChatV2/ChatViewController.swift` | UIKit 会话核心：消息列表、输入栏、键盘、表情面板、附件、录音 |
| `Sources/Features/Chat/UIKit/ChatTimelineCells.swift` | 原生消息 cell：文本、图片、视频、语音、文件、贴纸 |
| `Sources/Features/Chat/UIKit/ChatStickerPanelView.swift` | 原生 emoji/贴纸面板，支持收藏、分组、添加图片贴纸 |
| `Sources/Features/Chat/ChatHomeView.swift` | 首页：状态、快捷互动、贴条、最近消息 |
| `Sources/Features/Records/RecordsView.swift` | 在一起天数、纪念日、本地聊天统计、大橘日记/今日推荐 |
| `Sources/Features/Reminders/RemindersView.swift` | 提醒/备忘 CRUD（个人+共享）、本地通知 |
| `Sources/Features/Pet/PetView.swift` | 大橘 tab：**宠物数值与动作为占位**；「和大橘聊聊」进 ai 频道 |
| `Sources/Features/Profile/ProfileView.swift` | 连接状态、头像上传、外观、日期设置、Bark、存储空间、退出登录 |
| `Sources/Features/Profile/StorageView.swift` | 本地占用、全量同步聊天记录、缓存图片、文件管理 |
| `Sources/DesignSystem/DS.swift` + `Theme.swift` | 设计令牌、5 主题色、深浅模式、壁纸 |

### 后端关键文件

| 文件 | 说明 |
|---|---|
| `server/src/server.ts` | 启动 Fastify + Socket.IO |
| `server/src/db/index.ts` | PostgreSQL 连接池与建表 |
| `server/src/socket/realtime.ts` | Socket.IO 协议 |
| `server/src/chat/messageService.ts` | 消息 CRUD、搜索、撤回 |
| `server/src/personalItems/*` | 提醒/备忘 REST + 共享广播 |
| `server/src/ai/*` | 大橘 AI 全套（见 `docs/AI.md`） |

---

## 三、当前后端

- Node.js + TypeScript + Fastify + Socket.IO v4
- **PostgreSQL**（`pg` 连接池），见 `docs/POSTGRES.md`
- pm2 + nginx 部署

### 生产环境变量

模板：`server/.env.production.example`

```env
NODE_ENV=production
PORT=8080
HOST=127.0.0.1
PUBLIC_BASE_URL=https://hoo66.top
TOKEN_SECRET=固定的长随机字符串
DATABASE_URL=postgres://couplechat:强密码@localhost:5432/couplechat
COUPLECHAT_ACCOUNTS=xu|小旭|真实密码|🐶;si|小偲|真实密码|🐰
APP_DEEP_LINK_SCHEME=couplechat://
```

`TOKEN_SECRET` 必须长期固定，一变所有 token 失效。

AI 环境变量详见 `server/docs/AI.md` 与 `.env.production.example`（`AI_*`、`AI_VISION_*`、`EMBEDDING_*`）。

### 部署

见 `server/docs/DEPLOY.md`。生产主机 `root@82.40.34.107`，仓库 `/opt/couplechat-ios`，PM2 进程 `couplechat-server`。

**备份 PostgreSQL + uploads + .env**，不要用旧的 SQLite 备份命令。

---

## 四、接口契约

完整见 `server/docs/API.md`。核心摘要：

### REST

| 接口 | iOS 是否使用 |
|---|---|
| `GET /health` | 间接（healthcheck 脚本） |
| `GET /api/accounts` | ✅ 登录页 |
| `POST /api/login` | ✅ |
| `GET /api/me` | ✅ token 二次核实 |
| `POST /api/upload` | ✅ 图片/视频/语音/文件/贴纸/头像 |
| `GET/POST/PATCH/DELETE /api/me/items` | ✅ 提醒页 |
| `POST /api/me/push/bark` | ✅ 我的页 |
| `GET /api/daily`, `POST /api/daily/recommend` | ✅ 记录页 |
| `GET /api/stats` | ❌ 记录页改成本地聚合 |

### Socket.IO

连接：`io("https://hoo66.top", { auth: { token } })`

逻辑频道：`couple`、`ai`（服务端 ai 私聊存为 `ai:<username>`）

| 事件 | iOS |
|---|---|
| `message:send` / `message:new` | ✅ |
| `messages:fetch` / `messages:search` | ✅ |
| `message:recall` / `message:recalled` | ✅ |
| `message:update` / `action:confirm` | ✅ AI 确认卡 |
| `read` / `read:init` / `read:update` | ✅ |
| `presence` / `away` / `health` | ✅ |
| `shared:init/update/set` | ✅ |
| `ai:typing` | ✅ |
| `personalItem:changed` | ✅ 共享提醒刷新 |

---

## 五、iOS 当前能力

### 已完成

**聊天**
- couple / ai 双频道文字收发
- UIKit Chat V2 会话页：`UICollectionView` 原生消息列表 + UIKit 输入栏
- 图片 / 视频 / 语音（按住说话、左滑取消）/ 文件
- emoji 面板 + 本机贴纸库：分组、收藏、添加图片贴纸、发送 `sticker` 消息
- 乐观发送、失败重发（文字）、历史拉取、上滑加载更早
- 已读回执、在线状态、前后台 away/health
- 长按菜单：复制 / 引用 / 撤回（2 分钟内）
- 引用回复 UI（replyTo + replyPreview）
- 搜索 + 点击结果跳转到消息位置
- 媒体库、图片/视频预览与保存、文件打开
- 8 款预设壁纸 + 自定义照片（couple/ai 独立）
- 猫猫按钮 = 插入 `@大橘 `；大橘 tab 进 ai 私聊
- AI 确认卡、联网来源卡片
- 互动特效 overlay（想你了/拍一拍等）+ 贴条 `screen_note`

**本地**
- SQLite 全量缓存（`ChatLocalDatabase`），离线可看历史
- 记录页聊天统计从本地消息聚合（`localStats`），断网也能看
- 图片磁盘缓存（`ImageCache`），存储空间页可统计/清理；可手动缓存全部图片/贴纸

**其他页面**
- 登录 + session 持久化（Keychain + UserDefaults 兜底）
- 记录页：在一起天数、纪念日 CRUD、大橘日记/今日推荐
- 提醒页：提醒/备忘 CRUD（个人+共享）、Markdown 编辑、本地通知
- 我的页：连接状态、头像上传、5 主题色、深浅模式、日期设置、Bark 配置、存储空间、退出登录

**后端 AI**
- 意图判断、记忆召回、识图、联网、确认卡、每日维护（配好 env 即生效）

### 未完成 / 占位

| 项 | 说明 |
|---|---|
| 大橘 tab 宠物 | 饱食/清洁等数值硬编码，互动按钮仅 haptic，🐱 emoji 占位 |
| `needPetStatus` | 意图能识别，但服务端/iOS 均无真实宠物状态源 |
| Bark deep link | 点击通知打开指定页面未接 |
| 旧历史导入生产 | 38 万条消息只在本地开发库，生产库干净 |
| 大橘 3D 模型 | SceneKit 加载 `cute_cat.glb` 未做 |
| 媒体失败重传 | 媒体发送失败后无原始 Data 保留，不能一键重传 |

---

## 六、ChatStore 可靠性要点

1. **多频道**：`messagesByChannel["couple"]` / `["ai"]`
2. **乐观发送**：`clientId` 去重，ack 或 `message:new` 替换 pending
3. **重连补漏**：按最后一条非 pending/failed 的 `ts` 做 `since` 增量
4. **假连接**：回前台 `health`，2.5s 超时 disconnect + reconnect
5. **unauthorized**：先 `GET /api/me` 核实，确认无效才 logout
6. **shared 变更**：写入 SQLite + 广播；纪念日走 `dates` / `anniversaries` key

---

## 七、构建与安装

GitHub Actions：`.github/workflows/build-ios.yml`（push `main` 或手动触发）

```bash
gh workflow run "Build iOS IPA (unsigned)" --ref codex/chat-v2-uikit
```

产物 artifact：`couplechat-native-ipa` → SideStore/iloader 安装。免费 Apple ID 签名 7 天过期。

仓库里另有手动 workflow `Build IPA`：配置 Apple 签名 secret 后可导出签名 IPA；未配置签名时只上传 `.app` artifact。

---

## 八、测试清单

### 后端

```bash
curl https://hoo66.top/health
curl https://hoo66.top/api/accounts   # 必须 xu, si
cd server && npm run healthcheck
```

### App 基础

1. 安装最新 ipa，用 `xu` 或 `si` 登录
2. 我的页显示「已连接 · hoo66.top」
3. 清后台再打开，不应回登录页
4. 发文字无红叹号；退出登录可用

### 聊天

1. 引用回复、长按复制/撤回
2. 搜索关键词 → 点结果跳到消息
3. 图片/视频/语音/文件收发
4. emoji 插入、图片贴纸添加/收藏/发送
5. `@大橘` 召唤；大橘 tab 私聊每条都回

### 提醒

1. 新建个人提醒 → 到点本地通知（需授权）
2. 新建共享备忘 → 对方刷新可见

### 记录

1. 聊天统计左右翻页（断网也能看，来自本地缓存）
2. 大橘日记/今日推荐（需 AI 配置）

### 我的

1. 头像从相册/相机上传后，聊天头像和首页头像刷新
2. 存储空间页可同步全部聊天记录、缓存全部图片、清理图片缓存

---

## 九、已知坑

- `chat.huhuhu.top` 是旧后端（`23.254.222.199`），跟 `hoo66.top`（`82.40.34.107`）是**两台机器**
- 账号必须 `xu/si`，不是 `alice/bob`
- `TOKEN_SECRET` 不能随意更换
- iOS 本地不能编译 Swift；错误靠 Actions 或 Mac
- `project.yml` deployment target 是 iOS 17.0；改低版本前要重新验证 SwiftUI API 与 Chat V2 桥接
- 时间戳统一毫秒，`Double` 承接
- 根目录 `data/` 是未跟踪的**极敏感私人数据**（旧后端导出），**绝不能提交 git**
- 后端数据在 PostgreSQL，备份用 `pg_dump`，不是拷 `.sqlite` 文件
- MiMo 识图/联网：`max_tokens` 太小会导致可见 content 为空；测图别用 Wikipedia 等不稳定 URL

---

## 十、账号和环境

| 东西 | 说明 |
|---|---|
| GitHub | `hugxu0` |
| 新后端 | `https://hoo66.top`，`root@82.40.34.107`，PM2 `couplechat-server` |
| 旧网站 | `https://chat.huhuhu.top`，`root@23.254.222.199` |
| 本地仓库 | `D:\Desktop\couplechat-ios` |
| iOS 服务器地址 | 硬编码 `Sources/Core/Models.swift` → `https://hoo66.top` |

---

## 十一、旧后端历史数据迁移（2026-07-07）

根目录 `data/` 含旧后端（`alice/bob`）导出：`chat.db`（387842 条消息）、AI 记忆、uploads。

**已做（仅本地开发库）**：
- `messages` / `ai_facts` / `ai_episodes` / `uploads` 已导入本地 PostgreSQL（经 SQLite 中转脚本）
- 用户名映射：`alice→xu`，`bob→si`

**未做**：
- `chunk_embeddings`、`shared` 表（纪念日/提醒旧数据）、`daily_cache` 未迁移
- **生产库完全没动**，仍从 `xu/si` 干净起步

若要导入生产：先在服务器 `pg_dump` 备份，再跑 `scripts/migrate-sqlite-to-postgres.ts`（或等价 SQL），详见 `docs/POSTGRES.md`。
