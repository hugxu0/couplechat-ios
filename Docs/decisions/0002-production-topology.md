# ADR-0002：日本入口、美国单写源站

- 状态：Accepted
- 日期：2026-07-16

## 决策

客户端只访问 `https://hoo66.top`。日本 RFCHost 负责公网 TLS 入口、WebSocket/HTTP 转发和冷灾备；美国 RackNerd 负责唯一可写的 Node、PostgreSQL、uploads、AI、Bark 与备份。

日本通过私有代理 header 访问美国 `chat.huhuhu.top` origin。两边不能同时启动可写后端；普通代码发布只部署美国 `server/`，不修改日本。

## 原因与代价

日本入口改善访问路径并隐藏源站，RackNerd 提供更充足资源。但链路增加一跳和两个 Nginx 故障点，因此必须使用本机、私有 origin、公开入口三层健康检查，并单独验证 WebSocket 和大文件上传。

详细端口与恢复边界见 `../operations/PRODUCTION_TOPOLOGY.md`。

