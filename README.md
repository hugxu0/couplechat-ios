# 悄悄话（CoupleChat）

只服务 `xu` 与 `si` 两位固定用户的私有情侣应用。仓库同时包含 iOS/iPadOS 客户端与服务端；两端协议、数据库迁移、验证和发布说明在同一提交中维护。

## 在 AI 工作区中的位置

CoupleChat 是 `D:\Desktop\AI\project` 下的独立应用项目。本仓库负责产品代码，VPS 项目负责运行它所需的服务器和入口。

- 工作区总览：[`../../README.md`](../../README.md)
- 基础设施与生产入口：[`../VPS/README.md`](../VPS/README.md)
- 文档索引：[`Docs/README.md`](Docs/README.md)

涉及线上服务时看 [`Docs/SERVER.md`](Docs/SERVER.md)；需要主机细节时再看 VPS 项目，不必为普通客户端改动读取整套运维资料。

## 当前基线

- iOS/iPadOS 26，Swift 5.9，SwiftUI + UIKit；客户端版本和工程配置以 [`project.yml`](project.yml) 为准，已验证发布状态见 [`Docs/PROJECT.md`](Docs/PROJECT.md)。
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
- [开发指南](Docs/DEVELOPMENT.md)
- [服务器与部署](Docs/SERVER.md)
- [iOS 构建、签名与安装](Docs/IOS.md)
- 客户端和服务端目录中的简短开发约定

## 单仓库结构

```text
Docs/                  当前设计、契约、开发与运维文档
Sources/               iOS/iPadOS 客户端
server/                Fastify/Socket.IO/PostgreSQL 服务端
.github/workflows/     质量验证与 unsigned IPA 构建
project.yml            XcodeGen 工程定义
```

服务端使用仓库内 PowerShell 脚本发布；脚本负责测试、打包、切换和健康检查。

## 最短验证

```powershell
cd server
npm run check
```

iOS 工程由 XcodeGen 生成；Windows 开发机通过 GitHub Actions 验证，Mac 可本地生成和编译工程。真机安装步骤见 [IOS.md](Docs/IOS.md)。

## 几个约定

- PostgreSQL 与 `uploads/` 是线上事实源；iOS SQLite 是设备缓存。
- 美国 RackNerd 是唯一可写主机；日本只做入口和中转，不运行 CoupleChat 后端或数据库。
- 数据库 migration 按版本追加；实现见 [`server/src/db/migrate.ts`](server/src/db/migrate.ts)。
- REST、Socket 或 Sync 字段变化时，记得同步客户端、服务端和 [`Docs/API.md`](Docs/API.md)。
- `.env`、生产数据、Apple 凭据和证书不要提交到 Git。
- 改完运行与改动相关的检查；只有真正部署后才更新线上版本记录。
