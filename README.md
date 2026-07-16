# 悄悄话（CoupleChat）

只服务 `xu` 与 `si` 两位固定用户的私有情侣应用。仓库同时包含 iOS/iPadOS 客户端与服务端；两端协议、数据库迁移、测试和发布说明在同一提交中维护。

## 当前基线

- iOS/iPadOS 26，Swift 5.9，SwiftUI + UIKit，客户端版本 `0.2.0 (11)`。
- Node.js 22、Fastify 5、Socket.IO 4、PostgreSQL 16。
- 客户端公开基地址：`https://hoo66.top`。
- 日本 RFCHost 只做公开入口和跨国反向代理；美国 RackNerd 是唯一可写应用与数据库主机。
- GitHub Actions 生成的是 **unsigned IPA**。三台自用设备通过免费 Apple Personal Team 在本机签名，签名配置每 7 天需要刷新。
- 仓库保持公开以使用公开仓库的标准 GitHub-hosted Actions；公开范围只包含源码和脱敏文档，运维与签名秘密永不进入 Git 或 artifact。
- `Sources/Resources/cute_cat.glb` 是受版本控制并随 App 发布的资源；授权说明见 `Sources/Resources/ThirdPartyNotices.txt`。

公开注册、邀请码、创建或加入其他情侣空间均不属于当前产品。

## 从这里开始

- [文档索引](Docs/README.md)
- [当前产品与验证状态](Docs/current/PROJECT.md)
- [已知问题与修复顺序](Docs/current/KNOWN_ISSUES.md)
- [端到端系统架构](Docs/architecture/SYSTEM_ARCHITECTURE.md)
- [数据同步与可靠性设计](Docs/architecture/DATA_SYNC.md)
- [生产拓扑](Docs/operations/PRODUCTION_TOPOLOGY.md)
- [服务端部署](Docs/operations/DEPLOYMENT.md)
- [AI 接手与服务器连接](Docs/operations/AI_HANDOFF.md)
- [免费账号签名与侧载](Docs/operations/IOS_SIDELOAD.md)
- [给 AI/开发者的工作规则](AGENTS.md)

## 单仓库结构

```text
CoupleChatTests/       iOS 单元测试
Docs/                  当前设计、契约、开发与运维文档
Sources/               iOS/iPadOS 客户端
server/                Fastify/Socket.IO/PostgreSQL 服务端
.github/workflows/     质量验证与 unsigned IPA 构建
project.yml            XcodeGen 工程定义
```

发布规范要求服务端包只包含 `server/` 子目录，并绑定精确 tag/commit 与 SHA-256；普通代码发布按部署文档的短路径人工执行，远程一键入口尚未实现，不会把整个项目复制到服务器。

## 最短验证

```powershell
cd server
npm run check
```

iOS 工程由 XcodeGen 生成；Windows 开发机通过 GitHub Actions 验证，Mac 可本地运行 Xcode 测试。真机安装步骤见 [IOS_SIDELOAD.md](Docs/operations/IOS_SIDELOAD.md)。

## 不可破坏的边界

- PostgreSQL 与 `uploads/` 是线上事实源；iOS SQLite 是设备缓存。
- 美国 RackNerd 是唯一可写主机；日本冷回滚服务不得与美国同时启动。
- 当前源码要求 schema v31。已有迁移不可删除或改写，新变化只能追加。
- REST/Socket/Sync 变化必须同时更新服务端、客户端、契约测试和文档。
- `.env`、生产数据、媒体副本、数据库备份、Apple 凭据、证书、provisioning profile、设备 UDID 和构建产物不得提交。
- 源码通过测试、CI 成功、IPA 已生成和线上已发布是四件不同的事，必须分别提供证据。
