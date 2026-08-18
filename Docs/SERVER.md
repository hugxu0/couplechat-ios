# 服务器与部署

```text
iPhone/iPad → https://hoo66.top → 日本 RFCHost（TLS/Nginx 入口）
  → Tailnet 100.102.27.64:13000（tailscale serve）
  → 小米 10 Ubuntu chroot（Fastify + PostgreSQL + uploads，唯一可写源站）
```

生产 Node 监听小米 10 chroot 内 `127.0.0.1:3000`；PostgreSQL 16（自编译，
mmap 共享内存 + POSIX 信号量，适配无 SYSVIPC 的 Android 内核）监听
`127.0.0.1:5432`。日本 HTTPS 在 `127.0.0.1:8444`。
SSH 别名 `racknerd` / `rfchost` 已配置；手机入口 `ssh -p 2222 server@100.102.27.64`。
主机私有信息在本机运维资料里，不入库。

## 常用检查

```powershell
curl.exe -fsS https://hoo66.top/health   # 公网（/live /ready 同理）
ssh -p 2222 server@100.102.27.64 "cat /home/server/apps/couplechat/RELEASE; ss -lnt | grep -E ':(3000|5432) '"
ssh rfchost "nginx -t && systemctl is-active nginx"
```

## 普通发布

不涉及 migration、批量数据修复或 uploads 结构变化时：

```powershell
.\server\deploy\publish-phone.ps1
```

脚本做本地检查（`npm run check`）、打包、推送手机、手机端构建与版本切换，
跑健康检查与账号/socket 校验，失败自动回滚上一版本目录。发布后确认：
RELEASE 是预期提交、三个健康接口正常、App 能收发一条消息。

手机端由 Magisk `service.d` 看护（42 备份 / 47 PostgreSQL / 48 应用），
崩溃自动拉起、开机自启；日常发布不需要登录手机操作。

## 带 migration 的发布

migration 只按版本追加，普通发布不跑 migrator。涉及 schema 变更时**旧版本
不兼容新库，出问题不能只回滚代码**，所以顺序必须是：

1. 先确认手机 NAS 上有最近一次可读备份（`/mnt/nas/backups/couplechat`，
   42 号每日自动，14 天滚动）；必要时手工再跑
   `/home/server/bin/couplechat-backup`；
2. 停公网写入，等在途 AI 回复排空；
3. `publish-phone.ps1 -WithMigrations`：脚本先做 pre-migration pg_dump
   （手机本地 `backups/`），再跑受控 migrator，然后切换并核验；
4. 核验健康接口、登录、收发、重复 `clientId`、AI 回复；
5. 失败时用备份恢复数据库后回滚版本目录，不能只切代码。

## Nginx 入口（日本）

配置在 `/etc/nginx/sites-available/hoo66.top`；仓库
`server/deploy/nginx-japan-edge-hoo66.top.conf` 是模板，部署前替换回源占位符
（当前为小米 10 Tailscale 地址 `100.102.27.64:13000`）。
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

- 纯代码问题：`publish-phone.ps1` 部署失败会自动回滚上一版本目录；
  手工回滚 = 切回上一 release 符号链接并重启（48 号看护自动拉起）。
- 已跑 migration：旧代码不兼容时，用 NAS 快照或手机本地 pre-migration dump
  恢复数据库后再切回旧版本。
- 入口出错：恢复 Nginx 配置副本，`nginx -t` 后 reload。

发布后在 [PROJECT.md](PROJECT.md) 更新一行当前状态即可，不写流水账。