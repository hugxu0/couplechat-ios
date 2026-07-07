# CoupleChat Server

「悄悄话」新后端，面向原生 iOS 客户端。简单、可部署、可备份。

## 技术栈

- Node.js + TypeScript
- Fastify：REST API
- Socket.IO v4：实时消息、在线、已读、shared 状态
- PostgreSQL（`pg` 连接池）：消息、记忆、提醒、账号
- Bark：离线推送
- AI（`src/ai/`）：大橘应答引擎、记忆系统、意图判断、识图、联网搜索

## 本地启动

```bash
cd server
cp .env.example .env
npm install
npm run dev
```

默认监听 `http://localhost:8080`。需本地 PostgreSQL，连接串见 `DATABASE_URL`（默认 `postgres://couplechat:couplechat@localhost:5432/couplechat`）。

首次启动会按 `COUPLECHAT_ACCOUNTS` 自动创建账号。账号种子格式：

```text
username|displayName|password|avatar;username|displayName|password|avatar
```

生产环境第一次启动后，可从 `.env` 删除明文密码种子；已有账号不会被覆盖。

## 已实现

**基础**

- 账号登录、HMAC token、Socket.IO 鉴权
- couple / ai 频道消息存储（ai 私聊存为 `ai:<username>`）
- 历史拉取、搜索、撤回、`clientId` 幂等
- 已读回执、在线状态、away
- shared 键值状态
- 图片 / 视频 / 语音上传（`GET /uploads/*` 静态服务）
- 提醒 / 备忘 CRUD（`personal` / `shared` scope）
- Bark key 绑定与离线推送、到点提醒扫描（60s）

**AI（大橘）**

- couple 频道 `@大橘` 召唤回复；ai 私聊每条都答
- 未配 `AI_*` 时 ai 频道本地兜底，couple 频道不插话
- 意图判断 → 记忆召回 / 识图 / 联网 / 任务概况
- 确认卡（建提醒 / 备忘等）、搜索来源卡片
- 每日维护管线（日记、事件卡、事实收口、人物卡）
- 冲突检测、主动插话（couple 频道后台）

**REST 端点**

| 方法 | 路径 |
|------|------|
| GET | `/health` |
| GET | `/api/accounts` |
| POST | `/api/login` |
| GET | `/api/me` |
| POST | `/api/me/push/bark` |
| POST | `/api/upload` |
| GET | `/api/stats` |
| GET | `/api/daily` |
| POST | `/api/daily/recommend` |
| GET/POST | `/api/me/items` |
| PATCH/DELETE | `/api/me/items/:id` |

完整契约见 [docs/API.md](docs/API.md)。AI 细节见 [docs/AI.md](docs/AI.md)。

## 数据目录

| 路径 | 说明 |
|------|------|
| PostgreSQL | 全部结构化数据（`DATABASE_URL`） |
| `uploads/` | 媒体文件 |
| `.data/ai_logs/` | AI trace 日志（不入库） |

`uploads/` 与 `.data/` 不入 git，部署时需持久化与备份。

## 部署

见 [docs/DEPLOY.md](docs/DEPLOY.md)。数据库迁移见 [docs/POSTGRES.md](docs/POSTGRES.md)。

```bash
npm ci && npm run build
pm2 start ecosystem.config.cjs
npm run healthcheck   # 检查 /health 与 xu/si 账号
```

## 冒烟测试

```bash
npx tsx scripts/smoke-postgres.ts
```

内嵌临时 PostgreSQL，覆盖消息、搜索、shared、提醒、AI 记忆等 15 项断言。
