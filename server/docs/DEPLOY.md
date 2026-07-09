# Deploy New Backend

目标：让 `hoo66.top` 指向新后端，并统一账号为稳定的 `xu / si`。旧网站继续留在 `chat.huhuhu.top`，不要覆盖。

## 重要原则

- 不再使用旧后端的 `alice / bob`。
- 生产环境账号 username 必须固定为 `xu / si`，后续不要改。
- 旧 App token 会在新后端下失效，这是正常的；重新登录一次即可。
- 如果要保留旧历史，需要先做 `alice -> xu`、`bob -> si` 的数据库迁移。否则新后端会从空库开始。
- 数据层是 **PostgreSQL**，不是 SQLite。备份用 `pg_dump`，详见 `docs/POSTGRES.md`。

## 首次部署

在服务器上：

```bash
cd /opt
git clone https://github.com/hugxu0/couplechat-ios.git couplechat-ios
cd /opt/couplechat-ios
git checkout main

cd server
cp .env.production.example .env
nano .env
```

安装 PostgreSQL 并建库（见 `docs/POSTGRES.md` 第一、二节）。

必须修改：

```env
TOKEN_SECRET=用 openssl rand -hex 32 生成
COUPLECHAT_ACCOUNTS=xu|小旭|真实密码|🐶;si|小偲|真实密码|🐰
PUBLIC_BASE_URL=https://hoo66.top
DATABASE_URL=postgres://couplechat:强密码@localhost:5432/couplechat
```

AI 相关（可选，不配时 ai 频道走本地兜底）：

```env
# 对话模型（OpenAI 兼容口填到 /v1；claude- 开头自动走 Anthropic 原生协议）
AI_BASE_URL=https://api.deepseek.com/v1
AI_API_KEY=sk-xxx
AI_MODEL=deepseek-chat
AI_TRIGGER_ALIASES=@大橘
# AI_CHAT_* / AI_TASK_* 可分别覆盖对话模型和后台任务模型

# 识图 + 联网搜索（同一个 MiMo 账号，两种能力）
# MiMo 是推理模型，max_tokens 给太小会在 reasoning_content 阶段截断，content 永远是空的
AI_VISION_BASE_URL=https://api.xiaomimimo.com/v1
AI_VISION_API_KEY=sk-xxx
AI_VISION_MODEL=mimo-v2.5

# 向量检索（多账号池，key 逗号分隔，失败自动换下一个）
EMBEDDING_MODEL=voyage-4
EMBEDDING_DIM=1024
EMBEDDING_VOYAGE_PROVIDER=voyage
EMBEDDING_VOYAGE_BASE_URL=https://api.voyageai.com/v1
EMBEDDING_VOYAGE_API_KEYS=pa-key1,pa-key2
# 也可配 MongoDB AI Gateway 作为 failover
# EMBEDDING_MONGODB_PROVIDER=mongodb-voyage
# EMBEDDING_MONGODB_BASE_URL=https://ai.mongodb.com/v1
# EMBEDDING_MONGODB_API_KEYS=al-key1,al-key2
```

完整说明见 `.env.production.example` 和 `docs/AI.md`。

安装并启动：

```bash
npm ci
npm run build
npm install -g pm2
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup
```

nginx：

```bash
sudo cp deploy/nginx-hoo66.top.conf /etc/nginx/sites-available/hoo66.top
sudo ln -sf /etc/nginx/sites-available/hoo66.top /etc/nginx/sites-enabled/hoo66.top
sudo nginx -t
sudo systemctl reload nginx
```

如果证书还没配：

```bash
sudo certbot --nginx -d hoo66.top
```

## 验证

```bash
curl https://hoo66.top/health
curl https://hoo66.top/api/accounts
npm run healthcheck
```

`/api/accounts` 必须返回 `xu, si`。检查 pm2 状态和日志：

```bash
pm2 list                                              # 状态应为 online
tail -f /root/.pm2/logs/couplechat-server-out-0.log   # 看有没有报错
```

配了 AI 的话日志里应有一行 `[ai] 大橘已就位（AI 模型已配置）`，以及 `[reminder] 到点提醒扫描已启动（60s 间隔）`。

然后在 iPhone 上重新登录 `xu / si`。

## 更新部署

```bash
cd /opt/couplechat-ios
git fetch
git checkout main
git pull
cd server
npm ci
npm run build
pm2 restart couplechat-server
```

## 数据备份

至少备份：

```text
PostgreSQL 数据库（pg_dump）     # 消息 / 记忆 / 提醒 / 账号
server/uploads/                  # 媒体文件
server/.data/ai_logs/            # AI trace 日志（排查用）
server/.env                      # 配置（含 TOKEN_SECRET 和 AI 密钥）
```

简单备份命令：

```bash
mkdir -p /opt/backups/couplechat
cd /opt/couplechat-ios/server
pg_dump -Fc couplechat > /opt/backups/couplechat/couplechat-$(date +%F-%H%M).dump
tar -czf /opt/backups/couplechat/uploads-$(date +%F-%H%M).tar.gz uploads .data/ai_logs .env
```

**部署前一定先备份**。`TOKEN_SECRET` 不能换，一换所有已登录 token 失效，用户回登录页。

从旧 SQLite 迁移到 PostgreSQL 的一次性脚本见 `docs/POSTGRES.md` 第三节。
