# 服务器与部署

这是个人项目的日常运维说明，目标是能快速看懂、发布和排查。当前线上版本记录在 [PROJECT.md](PROJECT.md)，更具体的主机信息放在工作区的 VPS 项目和本机私有运维资料中。

## 当前结构

```text
iPhone / iPad
  -> https://hoo66.top
  -> 日本 RFCHost：TLS、Nginx、WebSocket 转发
  -> Tailscale 私网
  -> 美国 RackNerd：Fastify + Socket.IO + PostgreSQL
```

| 主机 | 用途 |
|---|---|
| 日本 RFCHost | 公网入口和反向代理，不保存 CoupleChat 业务数据 |
| 美国 RackNerd | 运行应用、PostgreSQL 和 uploads，是唯一可写源站 |

客户端只连接 `https://hoo66.top`。生产 Node 服务监听美国主机的 `127.0.0.1:3000`，日本 HTTPS 站点在 `127.0.0.1:8444` 处理入口流量。

## 资料放在哪里

- 项目代码、公开拓扑和部署脚本：当前仓库。
- VPS 的当前状态：`D:\Desktop\AI\project\VPS`。
- SSH、主机地址和其他私有运维信息：`D:\Desktop\01_开发项目\VPS运维`。

密码、token、数据库连接串、代理 key、证书私钥和聊天数据不要写进仓库或问题记录。日常检查使用已经配置好的 `racknerd`、`rfchost` SSH 别名即可。

## 常用检查

公网入口：

```powershell
curl.exe -fsS https://hoo66.top/live
curl.exe -fsS https://hoo66.top/health
curl.exe -fsS https://hoo66.top/ready
```

美国应用：

```powershell
ssh racknerd
sed -n '1p' /opt/couplechat-ios/server/RELEASE
docker inspect couplechat-server --format 'status={{.State.Status}} restarts={{.RestartCount}}'
curl -fsS http://127.0.0.1:3000/health
```

日本入口：

```powershell
ssh rfchost
nginx -t
systemctl is-active nginx
curl -kfsS --resolve hoo66.top:8444:127.0.0.1 https://hoo66.top:8444/health
```

出现消息延迟时，先确认公网 `/health` 和 Socket.IO 是否可用，再判断是 App 重连、跨国链路还是美国服务端问题。

## 本地验证

服务端改动通常只需要：

```powershell
cd server
npm ci
npm run check
```

改到脚本或类型边界时再补跑：

```powershell
npm run typecheck
```

本地开发使用自己的 PostgreSQL 和 `.env`，不要把调试进程接到生产数据库。

## 普通发布

不涉及 migration、批量数据修复或 uploads 结构变化时，从仓库根目录运行：

```powershell
.\server\deploy\publish-server.ps1 -SshTarget racknerd
```

脚本会完成测试、打包、上传、构建镜像、切换服务和健康检查，失败时尝试恢复旧镜像。没有恢复标记时普通代码发布会给出警告并继续；migration、批量数据修复和 uploads 结构变化仍先准备备份，再走单独的数据发布步骤。

发布后简单确认四件事：

1. `RELEASE` 是预期提交。
2. 容器为 `running`，没有持续重启。
3. `/live`、`/health`、`/ready` 正常。
4. App 可以登录并收发一条消息。

## Nginx 变更

日本入口配置位于 `/etc/nginx/sites-available/hoo66.top`。仓库 `server/deploy/nginx-japan-edge-hoo66.top.conf` 是无密钥参考模板，部署前需要把回源占位符替换为美国主机的 Tailscale 地址，不应整份覆盖线上配置。美国主机不再使用独立的公网源站域名或 Nginx TLS 回源。

修改时保留一份配置副本，然后执行：

```bash
nginx -t
systemctl reload nginx
curl -fsS https://hoo66.top/health
```

入口应保留 WebSocket 转发、80 MiB 上传限制和 `server/deploy/nginx-security-headers.conf` 中的基础安全响应头。公网 `443` 先经过本机 stream SNI 分流，且 `proxy_protocol off`，所以 HTTP 层看到的 TCP 来源是回环。`hoo66.top` 的 stream 映射必须只把 Cloudflare 与本机流量送到 `127.0.0.1:8444`，把 `hoo66.top:other` 发往拒绝端口；HTTP 层随后只信任回环来源的 `CF-Connecting-IP`，将其恢复为 `$remote_addr`，再用该值覆盖 `X-Real-IP` 与 `X-Forwarded-For`。这三项必须一起变更，否则会把所有请求折叠为回环地址，或允许绕过 Cloudflare 的请求伪造来源。

美国 `13000` 源站只允许日本 Tailnet 节点，应用只监听回环；Fastify 因此只信任 `loopback` 与 Tailscale `100.64.0.0/10` 两段受控代理，再把解析后的 `request.ip` 用作登录限流键。不能扩大可信网段，不能恢复 `$proxy_add_x_forwarded_for` 接受客户端原始链，也不能重新开放 `hoo66.top:other` 到 HTTP 层。修改任一层后同时检查 `nginx -T` 中的 stream 映射、`set_real_ip_from`、`real_ip_header` 和两个转发头，再分别用两个真实公网客户端确认应用日志中的 IP 不相同。

## 数据库变更

migration 继续按版本追加，不回头修改已经在线使用的旧 migration。普通代码发布不运行 migrator。

Web 进程的数据库连接、普通语句、客户端查询、锁等待和空闲事务默认分别限制为 5 秒、30 秒、35 秒、5 秒和 30 秒，可用 `DATABASE_*_TIMEOUT_MS` 调整。AI provider 调用在数据库事务之外使用各自更长的 AbortSignal，不受该限制。独立 `npm run migrate` 使用单独连接池，不继承 Web 查询上限，避免大 migration 被普通请求阈值中断。

当前生产为 schema v34，待发布源码为 v36：v35 重建消息幂等索引，v36 新增持久 AI 回复任务。这一批次不能调用“普通发布”直接切换，也不能依赖其旧镜像自动回滚，因为旧进程重启时不接受 v36。维护窗口必须：

1. 停止公网写入，等待旧进程正在执行的 AI 回复在既定上限内排空；不要对 v34 之前已存在的历史消息盲目回填回复任务。
2. 制作同一时点的 PostgreSQL 与 uploads 手工恢复点，并在隔离库至少验证结构版本、核心表计数、序列和媒体抽样。
3. 用待发布源码的独立 migrator 顺序执行 v35、v36，再启动同一批次的新应用。
4. 核验三个健康接口、schema、容器重启数、登录、文字/媒体收发、重复 `clientId`、AI 回复和断线补回。
5. 新版本失败且旧代码不兼容新 schema 时，停止写入并同时恢复该批次数据库、uploads 和旧镜像；不能只切回旧镜像。

只有下面这些改动需要比平时多做一步准备：

- 新 migration 或批量数据修复；
- uploads 目录、媒体格式或签名规则发生不兼容变化；
- 需要迁移或重建美国源站。

这类操作前保存一份可用的 PostgreSQL 和 uploads 备份，确认能读，再执行变更。项目不启用持续自动备份；普通小版本不要求完整恢复演练，但 schema、批量数据和主机迁移必须为当次变更制作并验证恢复点。

## 回滚

- 纯代码问题：切回上一镜像，再检查健康接口。
- 数据库已经迁移：先判断旧代码是否兼容新 schema；不兼容时再使用同一批次的数据备份恢复。
- 日本入口出错：恢复修改前的 Nginx 配置，运行 `nginx -t` 后 reload。

## 简单记录

真正发布或调整入口后，在 [PROJECT.md](PROJECT.md) 更新当前版本、检查日期和未完成事项即可。硬件状态、系统包数量和临时排障过程不用长期写进项目文档。
