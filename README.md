# 悄悄话（CoupleChat）

只服务 `xu` 与 `si` 两位固定用户的私有情侣应用。单仓库包含 iOS/iPadOS 客户端与
服务端，两端协议在同一提交中维护。没有注册、邀请码或多空间。

- 客户端：iOS/iPadOS 26，Swift 5.9，SwiftUI + UIKit（工程由 `project.yml` 生成）
- 服务端：Node.js 22、Fastify 5、Socket.IO 4、PostgreSQL 16
- 公开基地址 `https://hoo66.top`；日本只做入口中转，美国是唯一可写主机
- CI 产出 unsigned IPA，自己的设备用免费 Personal Team 签名（约 7 天刷新）
- 仓库保持公开；运维与签名秘密永不进 Git（`private/` 已 gitignore）

## 结构与文档

```text
Docs/                  文档（从 Docs/README.md 进入）
Sources/               iOS 客户端
server/                服务端
.github/workflows/     CI 与 IPA 构建
```

从 [文档索引](Docs/README.md) 进入；日常最常用的是
[现状](Docs/PROJECT.md)、[API 契约](Docs/API.md)、[部署](Docs/SERVER.md)。

## 最短验证

```powershell
cd server
npm run check
```

iOS 在 Windows 上靠推送后的 GitHub Actions 编译；真机安装见 [IOS.md](Docs/IOS.md)。

## 几个硬约定

- PostgreSQL 与 `uploads/` 是事实源；iOS SQLite 只是设备缓存。
- migration 按版本追加，不改历史；带 migration 的发布走 [SERVER.md](Docs/SERVER.md)。
- REST/Socket/Sync 字段变了，同一提交里更新两端和 [API.md](Docs/API.md)。
- Debug 与 Release 都连生产，调试时别批量删改数据。
