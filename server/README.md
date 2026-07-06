# CoupleChat Server

可长期维护的“悄悄话”新后端。它面向原生 iOS 客户端设计，但保留简单、可部署、可备份的形态。

## 技术栈

- Node.js + TypeScript
- Fastify：REST API
- Socket.IO：实时消息、在线、已读、shared 状态
- SQLite + sql.js：单机部署、容易备份，避免原生编译依赖
- Bark：离线推送通道
- AI 服务边界：当前本地兜底回复，后续可替换为真实模型

## 本地启动

```bash
cd server
cp .env.example .env
npm install
npm run dev
```

默认监听 `http://localhost:8080`。首次启动会按 `COUPLECHAT_ACCOUNTS` 自动创建账号。

账号种子格式：

```text
username|displayName|password|avatar;username|displayName|password|avatar
```

生产环境第一次启动后，可以从 `.env` 删除明文密码种子；已有账号不会被覆盖。

## 部署建议

详细步骤见 [docs/DEPLOY.md](docs/DEPLOY.md)。核心要求：

1. 在 VPS 安装 Node.js 22+。
2. 配置 `.env`，账号必须固定为 `xu / si`。
3. 执行 `npm ci && npm run build`。
4. 用 pm2 启动 `ecosystem.config.cjs`。
5. 用 nginx 反代到 `127.0.0.1:8080`，开启 HTTPS。
6. 定期备份 `server/.data/couplechat.sqlite` 和 `server/uploads/`。

## 数据目录

- SQLite：`server/.data/couplechat.sqlite`
- 上传文件：`server/uploads/`

这两个目录不入库，部署时需要持久化。

## 存储说明

当前版本用 `sql.js` 运行 SQLite，写入后会把数据库原子落盘到 `server/.data/couplechat.sqlite`。两个人的小型私密 App 足够使用，而且部署机器不需要 C++ 编译工具链。后续如果要换成原生 SQLite 或 Postgres，业务逻辑主要集中在 `src/*/*Service.ts`，迁移边界比较清楚。

## 当前状态

已实现：

- 账号登录
- 无状态 HMAC token
- Socket.IO 鉴权
- couple / ai 频道消息存储
- 历史拉取、搜索、撤回
- 乐观发送所需的 `clientId` 幂等
- 已读回执
- 在线状态和 away
- shared 键值状态
- 图片/视频上传
- Bark key 绑定和离线推送

预留但未实现完整业务：

- 真实 AI 模型接入
- 图片压缩、视频转码、缩略图
- 管理后台
- 数据迁移 CLI
