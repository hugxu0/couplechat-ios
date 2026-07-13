# 生产部署

## 当前拓扑

```text
Internet
  → nginx :443 · hoo66.top
  → couplechat-server :8080 · Docker host network
  → PostgreSQL :5432 · 仅服务器本机

持久化目录：
  /opt/couplechat-ios/server/uploads
  /opt/couplechat-ios/server/.data
  /opt/couplechat-ios/server/.env
```

生产主机为 RFCHost VPS，项目目录为 `/opt/couplechat-ios/server`。服务器登录方式、密钥和灾备记录保存在开发机的 VPS 运维资料中，不写入 Git 仓库。

## 生产文件

| 文件 | 用途 |
|---|---|
| `server/Dockerfile` | Node.js 生产镜像 |
| `server/compose.production.yml` | 容器、卷、资源和日志策略 |
| `server/deploy/nginx-rfchost-hoo66.top.conf` | 当前 nginx 站点模板 |
| `server/.env.production.example` | 不含密钥的最小生产配置模板 |
| `server/.env` | 生产密钥与连接配置，仅服务器存在 |

## 必要配置

```env
NODE_ENV=production
HOST=127.0.0.1
PORT=8080
PUBLIC_BASE_URL=https://hoo66.top
TOKEN_SECRET=<stable-random-secret>
DATABASE_URL=postgres://<user>:<password>@127.0.0.1:5432/couplechat
RUN_MIGRATIONS=false
COUPLECHAT_ACCOUNTS=xu|小旭|<password>|🐶;si|小偲|<password>|🐰
APP_DEEP_LINK_SCHEME=couplechat://
```

AI 和 embedding 配置见 [AI 系统](AI.md)。`.env` 权限应为 `600`，不能通过日志、聊天或 Git 传递完整内容。

## 更新服务

生产 Web 进程不会自动修改数据库。包含新 migration 的版本必须按“备份 → 短暂停写 → 单独 migrator → 启动候选 → 验证”的顺序发布；不要用普通容器启动来碰运气升级 schema。

```bash
cd /opt/couplechat-ios/server

# 1. 先生成并实际恢复校验一份备份，见下文“备份”。
# 2. 构建候选镜像，但先不要替换正式容器。
docker compose -f compose.production.yml build

# 3. 在与正式服务相同的环境中只运行一次 migrator。
docker run --rm --network host --env-file .env \
  couplechat-server:local npm run migrate

# 4. migrator 成功后再启动新版 Web 进程。
docker compose -f compose.production.yml up -d
```

`npm run migrate` 必须运行编译进生产镜像的 `dist/migrate.js`；不得依赖 runtime 中不存在的 `tsx` 或 TypeScript 源文件。构建候选后可先执行 `docker run --rm couplechat-server:local test -f dist/migrate.js` 验证入口存在。

高风险 migration 应通过 `BACKUP_QUIESCE_HOOK` 暂停写入；如果没有停写能力，至少先停止 Web 容器，再运行 migrator。迁移失败时不要反复重启新版服务，应保留现场并按已验证备份恢复。

在服务器项目目录执行：

```bash
cd /opt/couplechat-ios/server
docker compose -f compose.production.yml build
docker compose -f compose.production.yml up -d
docker compose -f compose.production.yml ps
curl -fsS http://127.0.0.1:8080/health
curl -fsS https://hoo66.top/health
```

发布前先备份，发布后检查容器日志：

```bash
docker compose -f compose.production.yml logs --tail=100 couplechat-server
```

不要直接把本机 `server/.data` 或空 `uploads/` 覆盖到服务器。

## nginx

站点需要：

- 将普通 HTTP 请求代理到 `127.0.0.1:8080`；
- 保留 `Upgrade` 与 `Connection` 头支持 Socket.IO；
- 允许上传体积覆盖服务端 50 MB 限制；
- 使用 HTTPS，并把 HTTP 重定向到 HTTPS。

应用模板前先运行 `nginx -t`，成功后再 reload。

## 备份

仓库提供轻量脚本，默认生成每日备份、周日副本、校验值并轮换保留 7 个日周期与 35 天周备份：

```bash
cd /opt/couplechat-ios/server
sudo BACKUP_ROOT=/root/codex-backups/couplechat \
  BACKUP_ALLOWED_PREFIX=/root/codex-backups \
  bash scripts/backup-production.sh
sudo VERIFY_DATABASE_URL='postgres://<verify-user>:<password>@127.0.0.1:5432/postgres' \
  VERIFY_ALLOWED_PREFIX=/root/codex-backups \
  bash scripts/verify-backup.sh \
  /root/codex-backups/couplechat/daily/<timestamp>
```

脚本从环境变量或当前 `.env` 读取 `DATABASE_URL`，但不会输出连接串。备份目录使用 `umask 077`，内容包括 PostgreSQL custom dump、uploads、非敏感部署文件、表计数、媒体清单和 SHA-256；默认不归档明文 `.env`。只有归档和全部校验成功后，随机临时目录才原子改名为正式备份。

`verify-backup.sh` 会创建随机临时数据库，完整恢复 dump、核对 migration 与核心表计数，并抽样解包验证媒体哈希，完成后删除临时数据库。`VERIFY_DATABASE_URL` 应使用具备 `CREATEDB`、但不是超级用户的专用校验账号；它绝不会指向要覆盖的生产数据库。若确实需要同时备份 `.env`，显式设置 `BACKUP_INCLUDE_ENV=1`，并把备份目录视为密钥材料管理。

正式定时任务建议设置 `BACKUP_REQUIRE_QUIESCE=1` 和绝对路径的 `BACKUP_QUIESCE_HOOK`。hook 接收 `begin <backup_id>` 与 `end <backup_id>`，用于短暂停写；未配置时备份会标记为 `best_effort`，适合当前小规模使用，但数据库和媒体文件之间不保证同一瞬间快照。

建议 root cron：

```cron
17 3 * * * cd /opt/couplechat-ios/server && BACKUP_ALLOWED_PREFIX=/root/codex-backups BACKUP_ROOT=/root/codex-backups/couplechat bash scripts/backup-production.sh >> /var/log/couplechat-backup.log 2>&1
```

每周至少对最新备份运行一次 `verify-backup.sh`；它会自动恢复到新的随机数据库并核对内容。真正灾备恢复仍必须使用新的空数据库和空媒体目录，确认结果后才能切换正式连接。

每次发布或高风险数据操作前至少保存：

1. PostgreSQL custom-format dump；
2. `uploads/` 媒体归档；
3. `.env` 与 compose/nginx 配置归档；
4. 文件校验值和备份时间。

示例：

```bash
backup=/root/codex-backups/couplechat-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
sudo -u postgres pg_dump -Fc couplechat > "$backup/couplechat.dump"
tar -czf "$backup/uploads.tar.gz" -C /opt/couplechat-ios/server uploads
tar -czf "$backup/config.tar.gz" -C /opt/couplechat-ios/server .env compose.production.yml
sha256sum "$backup"/* > "$backup/SHA256SUMS"
```

恢复前必须先在独立数据库验证 dump 可读，并再次备份当前状态。恢复属于高风险操作，不纳入日常部署命令。

## 发布后检查

- `/health` 返回 `200` 且 `database=ok`；
- `/api/accounts` 只返回 `xu`、`si`；
- iOS 可登录并完成一条公聊收发；
- Socket 重连、已读和在线状态正常；
- 媒体上传、访问和撤回后清理正常；
- `@大橘` 与 AI 私聊各完成一次回复；
- 容器没有持续错误、重启循环或异常内存增长。

## 2026-07-12 发布记录

本轮 R0-R8 发布已完成：

| 项目 | 记录 |
|---|---|
| 客户端候选 | `CoupleChat-unsigned-230` |
| 完整 CI | `29175140556`，全部通过 |
| 服务端候选 | `couplechat-server:candidate-6a2e833` |
| 正式标签 | `couplechat-server:local` |
| 回滚镜像 | `couplechat-server:rollback-20260712-094038` |
| 发布备份 | `/root/codex-backups/couplechat-release-20260712-094038` |

备份包含 PostgreSQL custom dump、uploads、配置归档和 `SHA256SUMS`，校验已通过。候选先在 `127.0.0.1:18080` 运行 canary，再切换正式容器。切换后本机与公网 health/readiness、固定账号、启动日志和重启次数均正常；用户随后完成普通消息、`@大橘`、AI 私聊和图片上传/预览冒烟。

VPS 内存有限，完整 Docker build 的 `npm ci` 可能触发内存不足。本次候选使用已验证的旧运行时镜像，仅覆盖本地 `npm run build` 生成的 `dist`。后续若继续采用该方式，必须先通过与 CI 同版本依赖的 `npm test`/`npm run build`，并在独立端口完成 canary；不得直接覆盖正式标签。

## 2026-07-13 V2 发布记录

| 项目 | 记录 |
|---|---|
| 主分支 | `32ec642` |
| 主分支 CI | `29211595691`，全部通过 |
| 客户端候选 | `CoupleChat-unsigned-252`，待真机 V2 回归 |
| 服务端候选 | `couplechat-server:candidate-32ec642` / image `35ce3ca0…` |
| 正式 schema | v22 |
| 应用回滚镜像 | `couplechat-server:rollback-20260713-064437-v10` |
| v10 恢复备份 | `/root/codex-backups/couplechat-v2-release/daily/20260712T223100Z-d9e287e294f5` |

发布前备份已完整恢复验证，并两次在隔离生产快照上完成 v10→v22；第二次同时启动完整 Web canary。正式切换后内外网 live/ready/health、nginx、账号列表、旧 token、bootstrap、消息读取、宠物与 Sync V2 均通过，容器 restart count 为 0。`COUPLECHAT_ACCOUNTS` 仅用于首次 seed，当前环境中的 seed 密码与历史数据库哈希不一致，因此发布自动化没有重置 legacy 密码；真机登录密码仍以数据库现有值为准。

## 2026-07-13 真机反馈第二轮

| 项目 | 记录 |
|---|---|
| 客户端/服务端提交 | `34dfc42` |
| 快速 Archive CI | `29215622552`，成功 |
| 客户端候选 | `CoupleChat-unsigned-258` |
| 服务端镜像 | `couplechat-server:candidate-34dfc42` / image `d82dae16…` |
| 正式 schema | v23 |
| 应用回滚镜像 | `couplechat-server:rollback-20260713-0842-round2` |
| 发布备份 | `/root/codex-backups/couplechat-round2/daily/20260713T004027Z-455f51483169` |

本轮加入相册照片/视频直传、撤回提示、共享宠物四状态五互动与 30 天日记读取。发布备份的 SHA-256 和 PostgreSQL dump 目录均已校验；候选先在 `127.0.0.1:18080` 通过 `/live`、`/ready` 与账号列表，再切换正式容器。切换后内外网健康检查、schema v23 和宠物字段核对通过，正式容器 restart count 为 0。
