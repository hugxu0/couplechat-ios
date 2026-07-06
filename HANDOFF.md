# 悄悄话 · 原生 iOS 版 — 交接文档

> 最后更新：2026-07-07
> 仓库：https://github.com/hugxu0/couplechat-ios
> 关联项目：网页版/旧后端 https://github.com/hugxu0/chat （部署在 https://chat.huhuhu.top）
> 新原生后端：本仓库 `server/`（计划部署在 https://hoo66.top）

---

## 一、项目是什么

双人私密聊天 App（就两个用户：小旭 `xu` / 小偲，账号定义在后端），原本是一个
Vue3 + Socket.IO 的 PWA（`hugxu0/chat` 仓库）。本仓库是它的 **SwiftUI 原生 iOS 重写版**，
目标是拿到网页做不到的原生体验：液态玻璃材质、触觉反馈、流畅动效（对标 Telegram 的手感）。

旧方案是后端零改动，原生 App 作为 `chat.huhuhu.top` 的第三个客户端。当前已改为
新原生后端路线：旧网站继续使用 `chat.huhuhu.top`，原生 App 和新后端走 `hoo66.top`。

**开发环境的根本约束：没有 Mac。** 所有构建都在 GitHub Actions 的 macOS 机器上完成，
本地（Windows）只写代码，看不到运行效果。因此每次改动的验证方式是：
推代码 → CI 出 ipa → iloader 装到 iPhone 上真机看。改 UI 细节时这个循环很慢，要有心理准备。

---

## 二、目录结构

```
couplechat-ios/
├── project.yml                  # XcodeGen 工程定义（依赖、Info.plist、构建设置都在这）
├── .github/workflows/build-ios.yml  # CI：出未签名 ipa
├── HANDOFF.md                   # 本文档
├── README.md                    # 简版说明
└── Sources/
    ├── App/
    │   ├── CoupleChatApp.swift  # 入口：登录门禁 + 前后台切换处理
    │   └── RootTabView.swift    # 自绘底部标签栏 + AppState（会话中隐藏底栏）+ Haptics
    ├── Core/
    │   ├── Models.swift         # ChatMessage / Account / Session（字段对齐服务端）
    │   ├── Keychain.swift       # 登录会话存钥匙串
    │   └── ChatStore.swift      # ★ 数据中枢：登录、socket、收发、断线恢复（最重要的文件）
    ├── DesignSystem/
    │   └── DS.swift             # ★ 设计令牌：全 App 圆角/颜色/透明度/间距/动画 唯一来源
    └── Features/
        ├── Auth/LoginView.swift       # 登录页（选头像 + 密码）
        ├── Chat/ChatHomeView.swift    # 聊天首页（情侣卡、互动按钮、消息预览）
        ├── Chat/ChatView.swift        # 会话页（气泡、输入栏、已读状态）
        ├── Records/RecordsView.swift  # 记录页（假数据）
        ├── Pet/PetView.swift          # 大橘页（假数据，emoji 占位 3D 猫）
        ├── Reminders/RemindersView.swift  # 提醒页（假数据，仅本地）
        └── Profile/ProfileView.swift  # 我的页（占位）
```

### 两条铁律

1. **所有视觉参数只从 `DS.swift` 取**：圆角（`DS.Radius`）、颜色（`DS.Palette`）、
   材质透明度（`DS.Surface`）、间距（`DS.Spacing`）、动画曲线（`DS.Anim`）。
   想全局换风格只改这一个文件。悬浮控制层（标签栏、输入栏按钮）统一用 `dsGlass(in:)`
   修饰符——iOS 26 上是真·系统液态玻璃（`glassEffect`），老系统自动退回半透明白。
   内容层（消息气泡、卡片正文）**故意不用玻璃**，保持不透明——这是苹果 HIG 的分层原则。
2. **所有按钮加 `PressableStyle`**（按压缩放回弹）、**状态切换不要包进 withAnimation 事务**
   （曾导致快速连点标签栏没反应，动画只标注在视觉属性上，用 `.animation(value:)`）。

---

## 三、后端接口契约（对齐 `hugxu0/chat` 仓库的 `src/`）

### REST（新原生后端 base = https://hoo66.top）

| 接口 | 说明 |
|---|---|
| `GET /api/accounts` | 公开账号表 `[{username, name}]`，登录页选人用 |
| `POST /api/login` `{username, password}` | 返回 `{token, username, name}`；失败 401 `{error}`；有频率限制（429） |
| `POST /api/upload` | 媒体上传（multipart，带 `Authorization: Bearer <token>`），**原生端还没接** |

token 是无状态 HMAC 签名，服务器重启不失效，客户端存钥匙串（`Keychain.swift`）。

### Socket.IO（服务端 v4；iOS 用 socket.io-client-swift 16.x）

握手：`socket.connect(withPayload: ["token": token])` → 服务端 `handshake.auth.token` 校验，
失败会 emit `error` 事件且消息含 "unauthorized"（ChatStore 里据此登出）。

| 事件 | 方向 | 说明 |
|---|---|---|
| `message:send` `{type,text,url,reply,meta,channel,clientId}` → ack `{ok,id}` | 发 | clientId 是乐观占位的临时 id，服务端广播时原样回传 |
| `message:new` | 收 | 新消息（含自己发的回声）；`channel` 是 `couple` 或 `ai` |
| `messages:fetch` `{channel, since/before/around, limit}` → ack `{list, replace}` | 发 | 四种模式：缺省=最近N条；since=增量补漏；before=翻更早；around=搜索跳转 |
| `messages:search` / `messages:date` | 发 | 全文搜索 / 按日期跳转（原生端未接） |
| `read` `{ts}` / `read:init` / `read:update {user,ts}` | 发/收 | 已读回执 |
| `presence` `{online:[username]}` | 收 | 在线表（前台可见才算在线） |
| `away` `bool` | 发 | 前后台上报。**很重要**：服务端靠它判断"对方没在看→发系统推送" |
| `health` → ack | 发 | 回前台探测假连接（iOS 冻结后 socket 假活），超时就强制重连 |
| `shared:set/init/update` | 发/收 | 键值共享数据（提醒、状态标签、宠物状态等都在这个体系里，原生端未接） |
| `message:recall` / `message:recalled` | 发/收 | 撤回（原生端只接了显示，没接发起） |
| `ai:typing` | 收 | 大橘"正在输入"（原生端未接） |

### 消息字段（`src/store/messages.js` 的 createMessage）

```
{ id, sender, senderName, kind(user|system), type(text|image|video|sticker|voice),
  text, url, reply, meta, channel(couple|ai), ts(毫秒), clientId? }
```

AI 频道说明：客户端只见逻辑频道 `ai`；服务端实际按 `ai:<username>` 隔离存储，
大橘私聊只推给本人。AI 全部逻辑在服务端（`src/ai/`、`src/chat/aiRuntime.js`），
客户端接入 AI 只需要：拉 `ai` 频道消息 + 显示 `ai:typing`，没有额外工作。

---

## 四、ChatStore 的可靠性设计（从网页版翻译过来的经验）

这些逻辑是网页版（`web/src/core/appSocket.js`）在 iOS PWA 上真实踩坑打磨出来的，
原生版在 `ChatStore.swift` 里等价实现了一遍，改动前先理解：

1. **乐观发送**：发送瞬间本地插入 `pending` 占位（id=clientId），ack 回来换真 id；
   广播若先到，`upsert` 按 clientId 对号入座替换占位，天然幂等不重复。
   ack 超时 15s → 标 `failed`，气泡旁红叹号可点重发。
2. **重连补漏**：连接（含自动重连）后，若本地已有消息，只 `since=最后一条ts` 增量拉，
   逐条 upsert，不整屏替换；本地为空才整批拉 80 条。
3. **假连接恢复**：回前台（scenePhase → active）时 `health` 探测（2.5s 超时），
   通了就增量补漏，超时说明是 iOS 冻结出的假连接 → 强制 disconnect + 重连。
4. **away 上报**：进后台立刻 `away true`。漏报会导致对方消息不触发服务端推送。

---

## 五、构建与安装

### CI 构建（唯一构建方式）

- 推 `main` 或手动触发 `Build iOS IPA (unsigned)` workflow。
- 流程：`brew install xcodegen` → `xcodegen generate`（从 project.yml 生成 .xcodeproj，
  工程文件不入库）→ `xcodebuild archive` 关签名 → 打成 `CoupleChat.ipa` 上传 Artifact。
- Xcode 用 `latest-stable`（maxim-lobanov/setup-xcode）。**不要写死版本**——
  曾在网页壳项目上因为 runner 默认 Xcode 太旧导致 Capacitor 模板编译失败。
- 仓库是公开的，因为 GitHub Actions 的 macOS 分钟数在私有仓按 10 倍计费，公开仓免费。

### 安装到 iPhone（无开发者账号的侧载路线）

前置（已完成，两台手机重复同样步骤）：电脑装 iTunes + **iloader**（iloader.app 或
github.com/nab138/iloader，仅这两处是正版）→ 数据线连手机 → iloader 登 Apple ID →
装 SideStore → 手机上信任开发者 + 开发者模式 → 装 StosVPN（App Store 国区搜不到，
用 fork 仓库 https://github.com/hugxu0/StosVPN 的 CI 构建 ipa 侧载）。

日常装本 App：CI Artifact 下载解压 → iloader "导入 IPA" → 完成。

### 续签（最重要的运维事项）

- 免费 Apple ID 签名 **7 天过期**，过期 App 打不开（数据不丢，重装即恢复）。
- **同时最多 3 个自签 App**（SideStore + StosVPN + 本 App = 满员）。
- SideStore 手机端自主续签在 iOS 26.x 上有未修复的官方 bug
  （"could not determine device's UDID"，github.com/SideStore/SideStore/issues/1305），
  所以目前的续签方式是：**每 5-6 天手机连电脑，iloader 里重新走一遍安装**
  （SideStore 稳定版按钮 / 导入 StosVPN ipa / 导入本 App ipa 各点一次）。
  证书如果被撤销/丢失，"管理配对文件"弹窗里的按钮**不会**重建证书，
  只有完整的安装/导入流程才会自动生成新证书。

---

## 六、当前进度

### 已完成 ✅

- 五页 UI 骨架（聊天首页/会话/记录/大橘/提醒/我的），自绘玻璃标签栏
- 设计令牌系统（DS.swift）+ 液态玻璃（iOS 26 真玻璃、老系统降级）
- 触觉反馈、按压回弹、页面无标题沉浸式、会话中隐藏底栏
- Telegram 式输入栏（附件钮、框内表情、语音/发送切换、点空白收键盘）
- **真后端**：登录（钥匙串持久化）、couple 频道收发、乐观发送/失败重发、
  已读双勾、在线状态、撤回显示、上滑翻历史、断线/回前台恢复
- CI 全链路 + 真机验证过

### 未完成 ⬜（按建议优先级）

1. **AI 大橘频道**：拉 `ai` 频道 + `ai:typing` 指示器 + 会话入口（工作量小，接口全现成）
2. **图片/视频**：`POST /api/upload` + 气泡里显示真图（现在媒体消息显示 `[图片]` 占位）+
   回形针按钮的附件菜单
3. **提醒/状态/宠物数据**：接 `shared:init/update`（现在这三页是假数据/仅本地）
4. **推送**：方案已定为 **Bark**（用户明确选定）。做法：后端 `pushToOffline`
   （src/chat/index.js）处发 Web Push 的旁边加一路 Bark HTTP 调用
   `https://api.day.app/<key>/标题/内容?icon=<头像url>&url=<唤起scheme>`；
   两人各自装 Bark App 拿 key；推送文案别带聊天原文（隐私，内容经 Bark 服务器中转）；
   给本 App 注册 URL Scheme 让点通知能跳回。**这是后端仓库的改动**，不在本仓库。
5. 长按菜单（撤回/回复/复制）、消息回复、搜索、语音消息
6. 大橘 3D：SceneKit/RealityKit 加载网页版同款 `web/public/cute_cat.glb`
7. 深色模式（DS.Palette 目前只有浅色一套值；Info.plist 里锁了 Light）

### 已知小坑

- `LoginView` 里头像 emoji 按 `username == "xu"` 硬编码（🐶/🐰），换账号体系要改
- `ChatView` 气泡头像也是硬编码 emoji，还没用后端的头像数据
- 消息时间分隔阈值 8 分钟，是拍脑袋值，跟网页版没精确对齐
- `defaultScrollAnchor(.bottom)` 要求 iOS 17+（deploymentTarget 已是 17.0，注意别降）
- 三端时间戳都是毫秒；Swift 里用 Double 承接（NSNumber 转换），别改成 Int 秒

---

## 七、需要的账号/环境

| 东西 | 说明 |
|---|---|
| GitHub `hugxu0` | 两个仓库的 owner；gh CLI 已在开发机登录 |
| Apple ID（gxhoo66@gmail.com） | 免费账号，iloader/SideStore 签名用；她那台用她自己的 Apple ID |
| VPS + hoo66.top | 新原生后端部署处（nginx + Node），HTTPS 需配置 |
| 开发机 | Windows 11，装了 iloader + iTunes；本仓库在 D:\Desktop\couplechat-ios |
