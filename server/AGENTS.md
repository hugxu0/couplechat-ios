# Server agent rules

先遵守根 `AGENTS.md`，再遵守本文件。

- 目标运行时 Node.js 22；使用 `npm ci`，不要无理由重写 lockfile。
- PostgreSQL 是事实源。migration 只追加，不修改 v1-v31；新 migration 必须可重复检查，并在隔离恢复库测试。
- 生产应用监听 `127.0.0.1:3000`。`8080` 只可作为明确的本地开发端口，不能进入生产默认值。
- `server.ts` 只装配进程，HTTP 在 `app.ts` 注册，业务进入对应领域 service/repository；Socket handler 只做契约解析、授权、调用和 ack/emit。
- REST/Socket/Sync 变化同时修改 iOS 契约、协议测试与根文档。
- 任何同步事件都必须通过统一写入边界，并在分配 `server_seq` 前取得同一 transaction-level advisory lock；修改该边界前先阅读 `Docs/architecture/DATA_SYNC.md` 并保留并发提交测试。
- 不直连生产做功能调试，不自动运行生产 migration，不读取或打印 `.env`、数据库 URL、AI key、Bark key、代理 key。
- 部署包只来自精确 tag/SHA 的 `server/` 子树；禁止以 root 下载并执行 moving `main`。

完成服务端改动至少运行：

```powershell
npm run check
```
