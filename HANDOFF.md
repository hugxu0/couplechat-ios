# 悄悄话 · 原生 iOS 版 — 交接文档

> 最后更新：2026-07-07
> 仓库：https://github.com/hugxu0/couplechat-ios
> 当前工作分支：`codex/new-backend-ios-media`
> 旧网页版/旧后端：https://github.com/hugxu0/chat（继续部署在 https://chat.huhuhu.top）
> 新原生后端：本仓库 `server/`（部署域名：https://hoo66.top）

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
| `Sources/Core/ChatStore.swift` | 登录、Socket、多频道消息、上传、已读、断线恢复 |
| `Sources/Core/Models.swift` | `Account` / `Session` / `ChatMessage` / `ChatChannel` |
| `Sources/Core/Keychain.swift` | 登录会话持久化；Keychain + UserDefaults 兜底 |
| `Sources/Features/Chat/ChatView.swift` | couple / ai 共用会话页，文字、图片、视频气泡 |
| `Sources/Features/Chat/ChatHomeView.swift` | 聊天首页 + 大橘入口 |
| `Sources/Features/Profile/ProfileView.swift` | 我的页，含连接状态和退出登录 |
| `Sources/DesignSystem/DS.swift` | 全局设计令牌 |

### 后端关键文件

| 文件 | 说明 |
|---|---|
| `server/src/server.ts` | 启动 Fastify + Socket.IO |
| `server/src/app.ts` | REST app、CORS、multipart、静态 uploads |
| `server/src/socket/realtime.ts` | Socket.IO 协议层 |
| `server/src/chat/messageService.ts` | 消息保存、历史、搜索、撤回、已读 |
| `server/src/auth/*` | 账号种子、密码哈希、token、REST 登录 |
| `server/src/upload/routes.ts` | 图片/视频上传 |
| `server/src/shared/sharedService.ts` | shared 键值状态 |
| `server/src/ai/aiService.ts` | 当前为本地兜底回复，后续接真实模型 |
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

### 部署

详细步骤见 `server/docs/DEPLOY.md`。

核心命令：

```bash
cd /opt/couplechat-ios/server
npm ci
npm run build
pm2 start ecosystem.config.cjs
pm2 save
```

nginx 示例：

```text
server/deploy/nginx-hoo66.top.conf
```

部署后必须验证：

```bash
curl https://hoo66.top/health
curl https://hoo66.top/api/accounts
```

`/api/accounts` 必须返回 `xu, si`。

---

## 四、接口契约

完整契约见 `server/docs/API.md`。这里列核心部分。

### REST

| 接口 | 说明 |
|---|---|
| `GET /health` | 健康检查 |
| `GET /api/accounts` | 返回 `[{username,name,avatar}]` |
| `POST /api/login` | `{username,password}` -> `{token,username,name}` |
| `POST /api/upload` | multipart 单文件上传，Bearer token |
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
| `shared:init/update/set` | 双向 | shared 键值状态 |
| `ai:typing` | 服务端 -> 客户端 | AI 输入中 |

---

## 五、iOS 当前能力

已完成：

- 登录页从 `hoo66.top/api/accounts` 拉账号
- 登录 session 持久化：Keychain + UserDefaults 备份
- 我的页显示连接状态，并有“退出登录”
- couple 频道文字收发
- ai 频道入口和会话页
- AI 当前有后端本地兜底回复
- 图片/视频选择、上传、发送
- 图片气泡 `AsyncImage` 预览
- 视频气泡卡片展示
- 乐观发送、失败状态、文本失败重发
- 历史拉取、增量补漏、上滑加载更早
- 已读回执
- 在线状态
- 前后台 `away` + 回前台 `health`
- 新后端部署文档和 nginx/pm2 配置
- CI 出未签名 ipa

未完成：

- `shared` 接到提醒/状态/宠物页面
- 真实 AI 模型接入
- Bark key 的 App 内配置页
- Bark 通知点击 URL Scheme 打开指定页面
- 长按菜单：复制/回复/撤回
- 消息回复 UI
- 搜索 UI / 按日期跳转 UI
- 视频播放预览
- 语音消息
- 大橘 3D 模型
- 深色模式

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

---

## 九、已知坑

- `chat.huhuhu.top` 是旧网站/旧后端，不要让原生 App 再指向它。
- 旧后端曾使用 `alice / bob`，新后端必须固定 `xu / si`。
- `TOKEN_SECRET` 不能每次部署都换，否则用户会反复回登录页。
- iOS 本地不能编译；Swift 编译错误只能靠 Actions 或 Mac/Xcode。
- `defaultScrollAnchor(.bottom)` 要求 iOS 17+，deployment target 不要降。
- 时间戳统一是毫秒，Swift 使用 `Double` 承接。
- 当前 `server/.data/`、`server/uploads/` 不入库，生产必须备份。

---

## 十、账号和环境

| 东西 | 说明 |
|---|---|
| GitHub | `hugxu0`，本机 gh CLI 已登录 |
| iOS 签名 Apple ID | `gxhoo66@gmail.com`；她的手机用她自己的 Apple ID |
| 旧网站 | `https://chat.huhuhu.top`，保留给旧 PWA |
| 新原生后端 | `https://hoo66.top` |
| 本地仓库 | `D:\Desktop\couplechat-ios` |
| 旧 PWA 仓库 | `D:\Desktop\chat` |
