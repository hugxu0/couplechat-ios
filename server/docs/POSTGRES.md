# PostgreSQL 迁移与部署

后端数据层已从 SQLite（`node:sqlite`）切换到 PostgreSQL（`pg` 连接池）。
好处：可以用任意图形化客户端（DBeaver / TablePlus / pgAdmin / DataGrip）直连服务器查看和管理数据。

服务启动时会执行 `src/db/index.ts` 中未应用的版本化迁移，并把结果记录在 `schema_migrations`。新增表或列时只追加新的迁移版本，不要修改已发布迁移。

## 一、服务器上安装 PostgreSQL（Ubuntu/Debian）

```bash
sudo apt update && sudo apt install -y postgresql
sudo systemctl enable --now postgresql
```

## 二、建库建用户

```bash
sudo -u postgres psql <<'SQL'
CREATE USER couplechat WITH PASSWORD '换成强密码';
CREATE DATABASE couplechat OWNER couplechat;
SQL
```

## 三、迁移旧数据（一次性）

在 `server/` 目录下（旧库在 `.data/couplechat.sqlite`）：

```bash
DATABASE_URL='postgres://couplechat:密码@localhost:5432/couplechat' \
  npx tsx scripts/migrate-sqlite-to-postgres.ts
```

- 幂等：全部 `ON CONFLICT DO NOTHING`，重复跑不会写脏。
- 可用 `SQLITE_PATH=/path/to/xx.sqlite` 指定其他源库。
- 迁移完成后建议把 `.data/couplechat.sqlite` 备份后移走。

### 旧网页生产库（legacy chat.db）

旧网页后端使用 `messages/shared/read_state/memory_facts/knowledge_cards/daily_cache` schema，不能直接使用上面的同构迁移脚本。停写并完成 `pg_dump` 后运行：

```bash
IMPORT_LEGACY_REPLACE=YES \
LEGACY_SQLITE_PATH=/root/import-couplechat/legacy-import.sqlite \
LEGACY_AI_DOCS_PATH=/root/import-couplechat/source-ai-docs \
LEGACY_UPLOADS_PATH=/opt/couplechat-ios/server/uploads \
npx tsx scripts/import-legacy-production.ts
```

该脚本保留 `accounts`（密码、Bark、登录配置），事务式替换其余业务表，完成 `alice/bob → xu/si`、提醒备忘、媒体索引和 AI 文档转换。运行前必须先执行 `npm run smoke:legacy-import`。

## 四、配置服务

在服务的环境（`.env` 或 systemd unit）里加：

```
DATABASE_URL=postgres://couplechat:密码@localhost:5432/couplechat
```

不设置时默认 `postgres://couplechat:couplechat@localhost:5432/couplechat`（仅限本地开发）。

## 五、远程 GUI 直连（可选）

PostgreSQL 默认只监听本机。**推荐做法：不开公网端口，用 SSH 隧道**——
在 DBeaver/TablePlus 里新建连接时选 SSH Tunnel，填服务器 SSH 账号，
数据库地址填 `localhost:5432`。这样数据库不暴露公网，安全且免配置。

如果一定要公网直连：改 `postgresql.conf` 的 `listen_addresses`、
`pg_hba.conf` 加 `hostssl` 行并强制 `scram-sha-256`，再在防火墙里只放行你的 IP。不建议。

## 六、验证

本仓库带一个完整冒烟测试（内嵌 PostgreSQL，不需要装任何东西）：

```bash
npx tsx scripts/smoke-postgres.ts
```

也可以直接运行 `npm test`。它会起临时 PG → 执行迁移 → 从 `.data/couplechat.sqlite` 全量迁移 → 跑消息分页/搜索/幂等发送/
已读回执/shared/提醒备忘 CRUD/AI 记忆向量/统计聚合与 Socket 契约断言。

## 实现说明

- `src/db/index.ts`：`pg` Pool；`run/all/get` 变异步；SQLite 风格 `?` 占位符自动转 `$n`；
  `int8`（BIGINT/COUNT）统一解析为 number；`Uint8Array`（embedding 向量）自动转 Buffer 走 BYTEA。
- 时间戳保持毫秒 BIGINT，服务层类型不变。
- 唯一的方言改写：`stats/routes.ts` 的 `strftime` → `to_char(to_timestamp(...))`。
- 日常备份：`pg_dump -Fc couplechat > backup.dump`（比拷 SQLite 文件更安全，不怕写入中途拷坏）。
