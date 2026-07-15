# 生产部署

## 当前拓扑

```text
iPhone / iPad
  → https://hoo66.top
  → 日本 RFCHost nginx（TLS 入口、WebSocket/HTTP 反代）
  → https://chat.huhuhu.top
  → 美国 RackNerd nginx（带私有代理密钥）
  → CoupleChat :3000
  → PostgreSQL :5432
```

美国 RackNerd 是唯一可写主服务器，运行 Fastify/Socket.IO、PostgreSQL、`uploads/`、AI 任务和推送。日本 RFCHost 只做入口和网络中转，旧后端与 PostgreSQL 处于停止状态，仅保留冷回滚数据。

| 角色 | 主机 | 目录/端口 |
|---|---|---|
| 公开入口 | 日本 RFCHost | `hoo66.top` / `127.0.0.1:8444` |
| 唯一应用主机 | 美国 RackNerd | `/opt/couplechat-ios/server` / `127.0.0.1:3000` |
| 主数据库 | 美国 RackNerd | PostgreSQL `127.0.0.1:5432/couplechat` |
| 媒体存储 | 美国 RackNerd | `/opt/couplechat-ios/server/uploads` |
| 私有 origin | 美国 RackNerd | `chat.huhuhu.top` / `127.0.0.1:10443` |

origin 必须校验 `X-CoupleChat-Proxy-Key`。密钥只保存在两台 VPS 的 root-only 文件和 nginx 实际配置中，不写入 Git。无密钥直连 `chat.huhuhu.top` 应返回 `403`。

## 生产文件

| 文件 | 用途 |
|---|---|
| `server/Dockerfile` | 生产镜像 |
| `server/compose.production.yml` | 应用编排，从 `.env` 取 `HOST`/`PORT` |
| `server/deploy/nginx-japan-edge-hoo66.top.conf` | 日本入口模板 |
| `server/deploy/nginx-racknerd-origin-chat.huhuhu.top.conf` | 美国 origin 模板 |
| `server/.env.production.example` | 不含密钥的参考配置 |
| `/opt/couplechat-ios/server/.env` | 美国生产密钥与连接串，权限 `0600` |
| `/opt/couplechat-ios/server/RELEASE` | 当前运行的完整 Git SHA |

主机必要配置：

```env
NODE_ENV=production
HOST=127.0.0.1
PORT=3000
PUBLIC_BASE_URL=https://hoo66.top
DATABASE_URL=postgres://<user>:<password>@127.0.0.1:5432/couplechat
TOKEN_SECRET=<stable-random-secret>
RUN_MIGRATIONS=false
COUPLECHAT_ACCOUNTS=xu|小旭|<password>|🐶;si|小偲|<password>|🐰
```

Web 容器不能自动跑 migration。发布必须按“备份 → 构建候选 → 单独 migrator → 启动 → 验证”执行。

当前代码要求 schema v31。v26 增加关系/理解对基础记忆的来源关联；v27 清空不再使用的原始消息证据，并把按消息记录的忘记规则合并为卡片 key 规则；v28 自动归档重复的当前近况、关系和理解卡片，并通过唯一索引保证每个滚动分区只有一张当前卡；v30 增加大橘自有记忆的视角和类型字段，并更新滚动卡唯一索引；v31 为今日推荐增加开放式分类标签。发布必须先备份，再停旧 Web、运行一次独立 migrator，确认迁移记录写入后才启动新镜像。

## 日常发布

### 1. 本地验证并生成发布包

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
git -c core.autocrlf=false archive --format=tar.gz `
  --output="build-artifacts/server-$Short.tar.gz" HEAD:server
Get-FileHash "build-artifacts/server-$Short.tar.gz" -Algorithm SHA256
```

把归档传到 RackNerd，在新目录解压，不覆盖 `.env`、`uploads/`和 `.data/`。

### 2. 生产备份

```bash
cd /opt/couplechat-ios/server
BACKUP_ALLOWED_PREFIX=/root/codex-backups \
BACKUP_ROOT=/root/codex-backups/couplechat \
  bash scripts/backup-production.sh
```

备份只有出现“备份已原子发布”才可继续。

### 3. 构建镜像与运行 migration

```bash
cd /opt/couplechat-ios/server
docker build -t couplechat-server:<short> .
docker run --rm couplechat-server:<short> test -f /app/dist/migrate.js

docker tag couplechat-server:local couplechat-server:rollback-$(date -u +%Y%m%dT%H%M%SZ)
docker compose -f compose.production.yml stop couplechat-server

docker run --rm --network host --env-file .env \
  couplechat-server:<short> npm run migrate

docker tag couplechat-server:<short> couplechat-server:local
docker compose -f compose.production.yml up -d --no-build
printf '%s\n' '<full-main-commit-sha>' > RELEASE
```

migration 失败时立即停止，不要连续重试或让旧镜像盲目访问新 schema。

### 4. 发布验证

```bash
curl -fsS http://127.0.0.1:3000/health
curl -fsS https://hoo66.top/health
curl -fsS https://hoo66.top/ready
curl -fsS https://hoo66.top/api/accounts
docker inspect couplechat-server \
  --format 'image={{.Image}} restarts={{.RestartCount}} status={{.State.Status}}'
docker logs --tail=100 couplechat-server
```

开发机额外执行：

```powershell
cd server
npm run healthcheck -- https://hoo66.top
```

还应在真机验证登录、Socket 重连、文字收发、图片/视频/表情上传、Range 媒体播放、多相册动态与全屏预览、计划、大橘和 AI 私聊。Bark 设置页可直接发送测试通知；通知入口应分别落到公聊、大橘私聊和提醒页面，URL scheme 为 `couplechat://`。

## 日本入口维护

普通 App 发布不修改日本 nginx。只在更换 origin 域名、代理密钥或证书时修改：

```bash
cp -a /etc/nginx/sites-available/hoo66.top \
  /root/codex-backups/nginx-$(date -u +%Y%m%dT%H%M%SZ)
nginx -t
systemctl reload nginx
curl -fsS https://hoo66.top/health
```

反代必须保留：

- WebSocket `Upgrade`/`Connection`；
- `proxy_request_buffering off`，避免大文件在日本落盘；
- 至少 80 MB 的 `client_max_body_size`；
- 300 秒读写超时；
- 美国 origin 的 TLS SNI 和私有代理密钥。

## 备份与回滚

RackNerd 当前任务：

```cron
0 3 * * * /bin/bash /root/backup/backup.sh >> /root/backup/backup.log 2>&1
30 4 * * 0 /usr/local/sbin/verify-couplechat-backup >> /root/backup/verify.log 2>&1
```

- 每日生成 PostgreSQL、uploads 和非敏感配置备份；
- 每周真实恢复到随机临时数据库并校验媒体；
- 本地保留按日/周轮换的当前备份；
- B2 同步是附加副本，失败不影响本地备份发布。

日本保留停用时的 PostgreSQL 数据目录、uploads、最终 dump 和旧镜像，但服务均不自启。回滚到日本前必须先停止美国写入，不允许两端同时可写。

## IPA 构建

IPA 与后端发布互相独立：

```powershell
gh workflow run build-ipa.yml --ref main
gh run list --workflow build-ipa.yml --branch main --limit 1
.\.github\scripts\download-latest-ipa.ps1
Get-FileHash build-artifacts\CoupleChat-latest.ipa -Algorithm SHA256
```

固定输出是 `build-artifacts/CoupleChat-latest.ipa`，不提交到 Git。
