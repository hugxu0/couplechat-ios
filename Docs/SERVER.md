# 服务器与部署

```text
iPhone/iPad → https://hoo66.top → 日本 RFCHost（TLS/Nginx 入口）
  → Tailscale → 美国 RackNerd（Fastify + PostgreSQL + uploads，唯一可写源站）
```

生产 Node 监听美国 `127.0.0.1:3000`；日本 HTTPS 在 `127.0.0.1:8444`。
SSH 别名 `racknerd` / `rfchost` 已配置；主机私有信息在本机运维资料里，不入库。

## 常用检查

```powershell
curl.exe -fsS https://hoo66.top/health   # 公网（/live /ready 同理）
ssh racknerd "sed -n 1p /opt/couplechat-ios/server/RELEASE; docker inspect couplechat-server --format 'status={{.State.Status}} restarts={{.RestartCount}}'"
ssh rfchost "nginx -t && systemctl is-active nginx"
```

## 普通发布

不涉及 migration、批量数据修复或 uploads 结构变化时：

```powershell
.\server\deploy\publish-server.ps1 -SshTarget racknerd
```

脚本做测试、打包、切换和健康检查，失败尝试回滚旧镜像。发布后确认：RELEASE
是预期提交、容器不重启、三个健康接口正常、App 能收发一条消息。

## 带 migration 的发布（当前 v34 → v36 就是这种）

migration 只按版本追加，普通发布不跑 migrator。涉及 schema 变更时**旧镜像
不兼容新库，出问题不能只回滚镜像**，所以顺序必须是：

1. 先做同一时点的 PostgreSQL + uploads 备份，并确认恢复点真的能读；
2. 停公网写入，等在途 AI 回复排空；
3. 用独立 migrator（`npm run migrate`，有单独连接池不受 Web 超时限制）跑新版本；
4. 启动同批次新应用，核验健康接口、登录、收发、重复 `clientId`、AI 回复；
5. 失败时连数据一起恢复到备份点，不能只切镜像。

项目没有持续自动备份——这是每次 migration 前必须手工做恢复点的原因。

## Nginx 入口（日本）

配置在 `/etc/nginx/sites-available/hoo66.top`；仓库
`server/deploy/nginx-japan-edge-hoo66.top.conf` 是模板，部署前替换回源占位符。
改完 `nginx -t && systemctl reload nginx` 再 curl 健康接口。

入口必须保留：WebSocket 转发、80 MiB 上传限制、安全响应头
（`nginx-security-headers.conf`）。真实 IP 链条的三件套要一起动，否则要么
全部请求折叠成回环、要么可伪造来源：

- stream SNI 只把 Cloudflare/本机流量送 `127.0.0.1:8444`，其余拒绝；
- HTTP 层只信回环来源的 `CF-Connecting-IP` 恢复真实地址；
- 用它覆盖 `X-Real-IP` / `X-Forwarded-For`（不要 `$proxy_add_x_forwarded_for`）。

Fastify 侧只信任 `loopback` + Tailscale `100.64.0.0/10`，`request.ip` 用作登录
限流键；不要扩大可信网段。

## 数据库超时

Web 进程默认：连接 5s、语句 30s、查询 35s、锁 5s、空闲事务 30s
（`DATABASE_*_TIMEOUT_MS` 可调）。AI 调用在事务外用自己的 AbortSignal。

## 回滚

- 纯代码问题：切回上一镜像，看健康接口。
- 已跑 migration：旧代码不兼容时，连数据库 + uploads 一起恢复到同批次备份。
- 入口出错：恢复 Nginx 配置副本，`nginx -t` 后 reload。

发布后在 [PROJECT.md](PROJECT.md) 更新一行当前状态即可，不写流水账。
