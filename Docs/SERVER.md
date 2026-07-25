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

入口应保留 WebSocket 转发、80 MiB 上传限制和 `server/deploy/nginx-security-headers.conf` 中的基础安全响应头。

## 数据库变更

migration 继续按版本追加，不回头修改已经在线使用的旧 migration。普通代码发布不运行 migrator。

只有下面这些改动需要比平时多做一步准备：

- 新 migration 或批量数据修复；
- uploads 目录、媒体格式或签名规则发生不兼容变化；
- 需要迁移或重建美国源站。

这类操作前保存一份可用的 PostgreSQL 和 uploads 备份，确认能读，再执行变更。个人项目不要求为每次小版本做完整恢复演练。

## 回滚

- 纯代码问题：切回上一镜像，再检查健康接口。
- 数据库已经迁移：先判断旧代码是否兼容新 schema；不兼容时再使用同一批次的数据备份恢复。
- 日本入口出错：恢复修改前的 Nginx 配置，运行 `nginx -t` 后 reload。

## 简单记录

真正发布或调整入口后，在 [PROJECT.md](PROJECT.md) 更新当前版本、检查日期和未完成事项即可。硬件状态、系统包数量和临时排障过程不用长期写进项目文档。
