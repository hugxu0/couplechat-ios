# 生产拓扑

> 最后私有运维记录：2026-07-14。域名、角色和端口已核对；上线前仍应现场检查 Cloudflare、Nginx、证书、容器、`RELEASE` 和 schema。本文不保存 IP、密码或任何密钥值。

## 流量路径

```text
iPhone / iPad
  → https://hoo66.top:443
  → 日本 RFCHost Nginx stream
  → 日本 127.0.0.1:8444（hoo66.top HTTPS vhost）
  → https://chat.huhuhu.top:443
  → 当前 DNS / Cloudflare 代理链路
  → 美国 RackNerd Nginx stream
  → 美国 127.0.0.1:10443（私有 origin HTTPS vhost）
  → 美国 127.0.0.1:3000（Fastify + Socket.IO）
  → 美国 127.0.0.1:5432（PostgreSQL 16）
```

客户端永远只使用 `hoo66.top`，不能直连 `chat.huhuhu.top`。日本转发时注入私有代理 header；美国 origin 缺少或不匹配时返回 `403`。代理 key 只存在于两台服务器 root-only 文件和实际 Nginx 配置，绝不进入 Git、日志或聊天。

公网 443 与主机上的其他私有服务共享 Nginx stream 分流；这些服务不属于 CoupleChat，公开仓库不记录其 SNI、端口或配置。修改应用 Nginx 前必须在私有运维资料中核对现有 stream 路由，避免影响其他流量。

## 角色与端口

| 角色 | 日本 RFCHost | 美国 RackNerd |
|---|---|---|
| CoupleChat 定位 | 公开 TLS 入口、跨国中转、冷灾备 | 唯一可写应用与数据主机 |
| HTTPS vhost | `127.0.0.1:8444` | `127.0.0.1:10443` |
| Node | 不运行 | `127.0.0.1:3000` |
| PostgreSQL | 停用，仅保留冷数据 | `127.0.0.1:5432/couplechat` |
| 项目目录 | 旧 `/opt/couplechat-ios/server` 仅冷回滚 | `/opt/couplechat-ios/server` |
| uploads | 冷数据 | `/opt/couplechat-ios/server/uploads` |
| 日常发布 | 不发布 | 只发布单仓库的 `server/` |

生产 Node 端口固定为 `3000`。美国 `8080` 已供其他服务使用；日本 `8080` 已停用。`8444` 与 `10443` 是 Nginx 回环 HTTPS 端口，不是 Node 端口。

## 两层反向代理约束

日本 edge 与美国 origin 都必须保留：

- HTTP/1.1 与 WebSocket `Upgrade`/`Connection`；
- `client_max_body_size 80m`；
- `proxy_request_buffering off` 与 `proxy_buffering off`；
- 至少 300 秒读写超时；
- 正确的 TLS SNI、`X-Forwarded-*` 和公开 Host；
- origin 私有代理 key 校验。

仓库模板位于 `server/deploy/`。模板包含占位符，不能直接覆盖生产配置；任何变更先备份、执行 `nginx -t`，再 reload 和逐层验证。

## 三层健康检查

1. **美国本机**：`http://127.0.0.1:3000/live|health|ready`；
2. **私有 origin**：带 root-only proxy key 请求 `https://chat.huhuhu.top/health`；不带 key 返回 `403` 是预期；
3. **公开入口**：`https://hoo66.top/live|health|ready`，并验证 Socket.IO 与上传。

只通过其中一层不能宣布发布成功。公开入口正常但 origin 无 key 返回 403，不是故障。

## 单写与冷回滚

美国是唯一可写事实源。日本旧容器、PostgreSQL 和 uploads 只用于美国主机不可恢复时的人工冷回滚：

1. 先停止美国所有写入；
2. 保存美国最后一份数据库与 uploads 一致备份；
3. 在隔离环境验证恢复；
4. 再切日本数据库、容器和入口；
5. 验证登录、消息、上传、Socket 和旧媒体。

严禁两边同时可写，当前系统没有多主复制或冲突合并能力。

## 现场核验项

- 日本冷数据不是实时复制，不能当作热备。
- 发布前在私有 runbook 核对最近成功的本地/离机备份、恢复演练和 RPO/RTO；公开仓库不记录供应商、容量或实时失败状态。
- 现场核对美国 origin 与日本 edge 的证书续期、Cloudflare 代理状态和 Nginx 实际参数。
- 迁移前读取生产 `RELEASE` 与 `schema_migrations`，不要用旧文档、公开健康检查或本地 artifact 猜线上版本。

更详细的 IP、SSH、DNS 账号、其他网络服务、订阅、代理 key 和数据库备份保存在仓库外的私有 VPS 资料中，不得复制到本项目。
