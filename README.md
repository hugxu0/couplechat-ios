# 悄悄话（CoupleChat）

只服务 `xu` 与 `si` 两位固定用户的私有情侣应用。仓库同时包含 iOS/iPadOS 客户端与服务端；两端协议、数据库迁移、验证和发布说明在同一提交中维护。

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
- [当前产品、验证和已知问题](Docs/PROJECT.md)
- [前后端与数据同步架构](Docs/ARCHITECTURE.md)
- [REST、Socket.IO 与 Sync 契约](Docs/API.md)
- [大橘 AI、Memory 与 MCP](Docs/AI.md)
- [开发指南与关键文件地图](Docs/DEVELOPMENT.md)
- [服务器、部署、备份与恢复](Docs/SERVER.md)
- [iOS 构建、签名与侧载](Docs/IOS.md)
- [给 AI/开发者的工作规则](AGENTS.md)

## 单仓库结构

```text
Docs/                  当前设计、契约、开发与运维文档
Sources/               iOS/iPadOS 客户端
server/                Fastify/Socket.IO/PostgreSQL 服务端
.github/workflows/     质量验证与 unsigned IPA 构建
project.yml            XcodeGen 工程定义
```

发布规范要求服务端包只包含 `server/` 子目录，并绑定精确 commit 与 SHA-256；普通代码发布由仓库内 PowerShell 入口完成一次验证、打包、上传、切换和健康检查，不会把整个项目复制到服务器。

## 最短验证

```powershell
cd server
npm run check
```

iOS 工程由 XcodeGen 生成；Windows 开发机通过 GitHub Actions 验证，Mac 可本地生成和编译工程。真机安装步骤见 [IOS.md](Docs/IOS.md)。

## 不可破坏的边界

- PostgreSQL 与 `uploads/` 是线上事实源；iOS SQLite 是设备缓存。
- 美国 RackNerd 是唯一可写主机；日本只做入口和中转，不运行 CoupleChat 后端或数据库。
- 当前源码要求 schema v31。已有迁移不可删除或改写，新变化只能追加。
- REST/Socket/Sync 变化必须同时更新服务端、客户端、契约说明、验证入口和文档。
- `.env`、生产数据、媒体副本、数据库备份、Apple 凭据、证书、provisioning profile、设备 UDID 和构建产物不得提交。
- 源码完成验证、CI 成功、IPA 已生成和线上已发布是四件不同的事，必须分别提供证据。
