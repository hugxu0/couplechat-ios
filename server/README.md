# CoupleChat Server

本目录是单仓库中的服务端子项目：Node.js 22、TypeScript、Fastify 5、Socket.IO 4 和 PostgreSQL 16。

## 本地验证

```powershell
npm ci
npm run check
```

本地开发使用自己的数据库和 `.env`。普通代码发布不运行 migrator；涉及 migration、数据修复或媒体结构变化时再单独处理数据步骤。

## 手机部署（实验性：小米 10）

源站可迁移到小米 10（Ubuntu 24.04 ARM64 chroot，无 Docker），公网入口
`https://hoo66.top` 不变。手机端看护脚本、环境初始化与迁移步骤见 VPS 运维
仓库 `docs/COUPLECHAT_MIGRATION.md`；本仓库提供：

```powershell
.\server\deploy\publish-phone.ps1            # 本地检查 + 打包 + 推送 + 远端安装
```

- 远端安装器：`server/deploy/deploy-phone.sh`（推送到 `/home/server/bin/`）。
- 手机端目录：`/home/server/apps/couplechat`（server symlink -> releases/<sha>，
  uploads/.data/.env 稳定不动），PostgreSQL 16 由 Magisk 看护直跑。
- 日常发布要求与 `publish-server.ps1` 一致（干净工作树、HEAD == origin/main）。
- 带 migration 的发布必须显式 `-WithMigrations`，脚本会先做 pre-migration
  pg_dump；切换/回滚流程见迁移文档。
## 文档

- [项目现状与已知问题](../Docs/PROJECT.md)
- [系统架构与数据同步](../Docs/ARCHITECTURE.md)
- [API 契约](../Docs/API.md)
- [服务器与部署](../Docs/SERVER.md)
- [开发指南](../Docs/DEVELOPMENT.md)

生产 Node 端口是 `3000`，`8080` 可用于本地开发。普通代码发布使用 `deploy/publish-server.ps1`，服务器初始化和主机配置放在 VPS 项目中。
