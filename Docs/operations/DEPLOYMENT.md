# 生产部署

## 当前拓扑

```text
Internet
  → nginx :443 · hoo66.top（唯一正式 API）
  → couplechat-server :8080 · Docker host network
  → PostgreSQL :5432 · 仅服务器本机

兼容域名 chat.huhuhu.top 只反向代理到 hoo66.top，
不得运行第二套可写 CoupleChat 后端。

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

AI 和 embedding 配置见 [AI 系统](../architecture/AI.md)。`.env` 权限应为 `600`，不能通过日志、聊天或 Git 传递完整内容。

## 更新服务

生产 Web 进程不会自动修改数据库。包含新 migration 的版本必须按“备份 → 短暂停写 → 单独 migrator → 启动候选 → 验证”的顺序发布；不要用普通容器启动来碰运气升级 schema。

### 发布约束

- 发布源只能是已经推送到 `main` 的确定 commit，生产目录用 `RELEASE` 文件记录实际运行的完整 SHA。
- RFCHost 内存较小，不在生产机执行完整 `docker build`。生产镜像在资源更充足的 Linux 构建机生成，通过 `docker save` 导出、SHA-256 校验后传入生产机。
- `.env`、`uploads/` 和 `.data/` 是生产持久化状态，代码同步必须显式排除；不得从本机或构建机覆盖。
- 旧镜像在切换前标记为 `couplechat-server:rollback-<UTC timestamp>`，数据库和媒体备份验证通过后才能迁移。
- Web 容器必须设置 `RUN_MIGRATIONS=false`；migration 只能由一次性 migrator 容器执行。

### 1. 本地验证与发布包

```powershell
git switch main
git pull --ff-only origin main

cd server
npm test
npm run build
cd ..

$Release = (git rev-parse HEAD).Trim()
$Short = $Release.Substring(0, 7)
New-Item -ItemType Directory -Force build-artifacts | Out-Null
git archive --format=tar.gz `
  --output="build-artifacts/server-$Short.tar.gz" HEAD:server
Get-FileHash "build-artifacts/server-$Short.tar.gz" -Algorithm SHA256
```

生产 SSH 地址、构建机地址和密钥位置只保存在开发机 VPS 运维资料中，不写入仓库。下文用 `<build-host>` 与 `<production-host>` 表示。

### 2. 生产备份

旧容器继续运行时先生成备份，并验证 dump 目录和 SHA-256：

```bash
cd /opt/couplechat-ios/server
BACKUP_ALLOWED_PREFIX=/root/codex-backups \
BACKUP_ROOT=/root/codex-backups/couplechat \
  bash scripts/backup-production.sh

latest=$(find /root/codex-backups/couplechat/daily \
  -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort -nr | head -n1 | cut -d' ' -f2-)
pg_restore -l "$latest/couplechat.dump" >/dev/null
(cd "$latest" && sha256sum -c SHA256SUMS)
```

同时备份当前 `.env`、Compose 文件和代码，并给旧镜像创建 rollback tag。备份目录必须位于 `/root/codex-backups` 且权限为 `0700`。

### 3. 在 Linux 构建机生成镜像

```bash
mkdir -p /root/codex-staging/release
tar -xzf /root/codex-staging/server-<short>.tar.gz \
  -C /root/codex-staging/release

docker build -t couplechat-server:<short> /root/codex-staging/release
docker run --rm couplechat-server:<short> test -f dist/migrate.js
docker save couplechat-server:<short> \
  | gzip -1 > /root/codex-staging/couplechat-server-<short>.tar.gz
sha256sum /root/codex-staging/couplechat-server-<short>.tar.gz
```

将镜像归档传到生产机 `/root/codex-staging/`，在生产机重新核对 SHA-256，然后导入：

```bash
gzip -dc /root/codex-staging/couplechat-server-<short>.tar.gz | docker load
docker image inspect couplechat-server:<short>
```

可在 `127.0.0.1:8081` 启动短生命周期 canary。若候选因“期望更新 schema”退出，应检查日志确认唯一原因是 migration 版本保护；不要让 canary 自动执行迁移。

### 4. 短暂停机、迁移与切换

```bash
cd /opt/couplechat-ios/server

# 候选镜像和 rollback tag 均已存在。
docker tag couplechat-server:<short> couplechat-server:local
docker compose -f compose.production.yml stop couplechat-server

# 在与正式服务相同的网络和环境中只运行一次 migrator。
docker run --rm --network host --env-file .env \
  couplechat-server:<short> npm run migrate

# migrator 成功后启动，不允许现场重新 build。
docker compose -f compose.production.yml up -d --no-build
printf '%s\n' '<full-main-commit-sha>' > RELEASE
```

`npm run migrate` 必须运行编译进生产镜像的 `dist/migrate.js`；不得依赖 runtime 中不存在的 `tsx` 或 TypeScript 源文件。构建候选后可先执行 `docker run --rm couplechat-server:local test -f dist/migrate.js` 验证入口存在。

高风险 migration 应通过 `BACKUP_QUIESCE_HOOK` 暂停写入；如果没有停写能力，至少先停止 Web 容器，再运行 migrator。迁移失败时不要反复重启新版服务，应保留现场并按已验证备份恢复。

### 5. 发布后验证

```bash
cd /opt/couplechat-ios/server
docker compose -f compose.production.yml ps
curl -fsS http://127.0.0.1:8080/health
curl -fsS https://hoo66.top/health
curl -fsS https://hoo66.top/api/accounts
sudo -u postgres psql -d couplechat -Atc \
  'select max(version) from schema_migrations'
docker inspect couplechat-server \
  --format 'image={{.Image}} restarts={{.RestartCount}} status={{.State.Status}}'
docker compose -f compose.production.yml logs --tail=100 couplechat-server
```

开发机还应执行：

```powershell
cd server
npm run healthcheck -- https://hoo66.top
```

验证成功后删除两台 VPS 的 `/root/codex-staging` 临时归档，但保留生产备份与 rollback 镜像。若 migrator 失败，不得启动候选；重新标记 rollback 镜像并执行 `docker compose up -d --no-build`。若 migration 已成功但新版启动失败，旧应用是否兼容新 schema 必须按该 migration 单独判断，不能盲目回滚。

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

## 旧 Chat 数据窗口迁移与域名切换

旧站替换属于一次性高风险数据操作，不并入日常发布脚本。目标是把指定时间窗口内的聊天、媒体、表情库和大橘日记导入正式库，同时避免双写和客户端残留垃圾数据。

执行顺序固定为：

1. 明确北京时间窗口、账号映射和频道映射，并生成只读盘点报告；
2. 停止旧站写入，完整备份旧数据库、媒体和配置，验证所有 SHA-256；
3. 停止正式后端，备份 PostgreSQL、`uploads/` 和部署配置，并验证 dump 可读；
4. 从停止后的旧库重新导出窗口数据，禁止使用盘点阶段的活动库副本；
5. 在一个数据库事务中替换目标窗口，保留源消息 ID、时间、回复关系和消息类型；
6. 媒体先按哈希验证再落盘。旧贴纸消息必须写为 `sticker`，不能退化成普通 `image`；自定义表情库写入共享 `couple_settings.stickers`，由客户端同步到双方设备；
7. 只为“目标库独有且被清除”的垃圾消息生成删除同步事件，不能给重新导入的同 ID 消息生成删除事件；
8. 大橘日记按日期写入 `ai_runtime_state`；Memory 按频道重置到窗口起点后重新扫描，`couple` 属于共同记忆，`ai:<username>` 属于对应用户的私人记忆；
9. 独立校验消息字段、分类型数量、媒体哈希、表情数量、日记和 Memory 游标，成功后再启动正式后端；
10. 旧站保持停止。旧域名如需兼容，只代理到 `hoo66.top`，绝不再启动第二套可写服务。

迁移器必须具备 dry-run、事务回滚、幂等键和独立验证器。任何一步数量或哈希不一致，都应恢复目标操作前备份，而不是在正式库上手工补数据。连接串、账号口令和源服务器地址只记录在开发机 VPS 运维资料中。

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

VPS 内存有限，完整 Docker build 的 `npm ci` 可能触发内存不足。服务端候选必须先通过与 CI 同版本依赖的 `npm test` 和 `npm run build`，再在独立端口完成 canary；不得直接覆盖正式标签。

## 构建与下载 IPA

IPA 与后端发布相互独立。`项目质量验证`不生成 IPA；只有手动工作流`构建 IPA`会归档 Release App。

```powershell
git switch main
git pull --ff-only origin main

gh workflow run build-ipa.yml --ref main
gh run list --workflow build-ipa.yml --branch main --limit 1

# 等工作流成功后，自动下载最近一次成功构建并覆盖固定文件：
.\.github\scripts\download-latest-ipa.ps1

Get-FileHash build-artifacts\CoupleChat-latest.ipa -Algorithm SHA256
```

固定输出为 `build-artifacts/CoupleChat-latest.ipa`。工作流 artifact 名同样固定为 `CoupleChat-latest`，并附带 `.sha256` 文件。不要把 IPA 提交到 Git。
