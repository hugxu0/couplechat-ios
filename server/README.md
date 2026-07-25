# CoupleChat Server

本目录是单仓库中的服务端子项目：Node.js 22、TypeScript、Fastify 5、Socket.IO 4 和 PostgreSQL 16。

## 本地验证

```powershell
npm ci
npm run check
```

本地开发使用自己的数据库和 `.env`。普通代码发布不运行 migrator；涉及 migration、数据修复或媒体结构变化时再单独处理数据步骤。

## 文档

- [项目现状与已知问题](../Docs/PROJECT.md)
- [系统架构与数据同步](../Docs/ARCHITECTURE.md)
- [API 契约](../Docs/API.md)
- [服务器与部署](../Docs/SERVER.md)
- [开发指南](../Docs/DEVELOPMENT.md)

生产 Node 端口是 `3000`，`8080` 可用于本地开发。普通代码发布使用 `deploy/publish-server.ps1`，服务器初始化和主机配置放在 VPS 项目中。
