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
COUPLECHAT_ACCOUNTS=xu|小旭|<password>|🐶;si|小偲|<password>|🐰
APP_DEEP_LINK_SCHEME=couplechat://
```

AI 和 embedding 配置见 [AI 系统](AI.md)。`.env` 权限应为 `600`，不能通过日志、聊天或 Git 传递完整内容。

## 更新服务

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
