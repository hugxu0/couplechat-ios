# 悄悄话 · 原生 iOS 版（SwiftUI + UIKit）

双人私密聊天 App 的 iOS 原生客户端，对应网页版 [hugxu0/chat](https://github.com/hugxu0/chat)。  
后端在本仓库 `server/`，部署于 `https://hoo66.top`；旧 PWA 仍保留在 `https://chat.huhuhu.top`，两者**不共用后端**。

## 现状

已接入新后端，核心功能可用：

- 登录（`xu` / `si`）、Socket.IO 实时聊天（couple + ai 频道）
- 文字 / 图片 / 视频 / 语音 / 文件 / 贴纸消息，已读回执，撤回，引用回复
- 本地 SQLite 缓存，离线可看历史；记录页统计从本地聚合；图片缓存可管理
- 提醒 / 备忘 CRUD（个人 + 共享），本地通知
- 大橘 AI（`@大橘` 召唤 + 私聊频道），确认卡、联网来源卡片
- 主题色 / 深浅模式 / 聊天壁纸（预设 + 自定义照片）、头像上传
- 互动特效（想你了 / 拍一拍 / 贴条等）

**仍是占位**：大橘 tab 的宠物数值与 3D 模型。

详细交接说明见 [`HANDOFF.md`](HANDOFF.md)。

## 架构

```
Sources/
├── App/                  入口、通知代理、自绘底部标签栏
├── Core/                 ChatStore、Models、Keychain、本地 SQLite 缓存、贴纸/图片缓存
├── DesignSystem/         DS.swift + Theme.swift（设计令牌与主题）
└── Features/
    ├── Auth/             登录
    ├── Chat/             聊天首页 + ChatV2 会话页（UIKit 消息列表/输入栏 + SwiftUI 外壳）
    ├── Records/          记录（纪念日、聊天统计、大橘日记）
    ├── Pet/              大橘 tab（AI 私聊入口；宠物 UI 占位）
    ├── Reminders/        提醒 / 备忘
    └── Profile/          我的（连接状态、头像、外观、日期、Bark、存储空间）

server/                   Node.js + Fastify + Socket.IO + PostgreSQL
```

改全局风格（圆角、玻璃、动画）主要改 `Sources/DesignSystem/DS.swift`；主题色与壁纸改 `Theme.swift`。聊天会话页的重构说明见 `Docs/CHAT_V2_ARCHITECTURE.md`。

## 构建

开发机在 Windows，本地不编译 iOS。推到 `main` 或手动触发 GitHub Actions，产出未签名 ipa，用 iloader / SideStore 签名安装。工程由 XcodeGen 从 `project.yml` 生成，不入库。

```bash
gh workflow run "Build iOS IPA (unsigned)"
```

另有手动 workflow `Build IPA` 可在配置 Apple 签名 secret 后导出签名 IPA；未配置签名时只上传 `.app` artifact。

## 后端本地启动

```bash
cd server
cp .env.example .env
npm install
npm run dev
```

需要 PostgreSQL（默认 `postgres://couplechat:couplechat@localhost:5432/couplechat`）。详见 `server/README.md` 与 `server/docs/POSTGRES.md`。

## 后续计划

1. 大橘 tab 真实宠物状态（服务端 `shared` / 独立存储）+ SceneKit 3D 模型
2. Bark 点击 deep link 打开指定页面
3. 旧后端历史数据导入生产库（目前只在本地开发库）
