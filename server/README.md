# CoupleChat Server

本目录是单仓库中的服务端子项目：Node.js 22、TypeScript、Fastify 5、Socket.IO 4 和 PostgreSQL 16。

## 本地验证

```powershell
npm ci
npm run check
```

开发必须使用隔离数据库和非生产 `.env`。普通生产代码发布不运行 migrator；涉及 migration、数据修复或媒体结构变化时，生产 Web 进程保持 `RUN_MIGRATIONS=false`，再由发布流程中的独立 migrator 执行。

## 文档

- [系统架构](../Docs/architecture/SYSTEM_ARCHITECTURE.md)
- [API 契约](../Docs/architecture/API.md)
- [数据同步](../Docs/architecture/DATA_SYNC.md)
- [生产拓扑](../Docs/operations/PRODUCTION_TOPOLOGY.md)
- [部署与恢复](../Docs/operations/DEPLOYMENT.md)
- [已知问题](../Docs/current/KNOWN_ISSUES.md)

生产 Node 端口是 `3000`；`.env.production.example`、Compose、Dockerfile 与健康检查的生产默认值已经统一。`8080` 只保留为显式的本地开发端口。普通代码发布使用 `deploy/publish-server.ps1`；首次安装仍需按私有运维资料人工准备。
