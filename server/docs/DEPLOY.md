# Deploy New Backend

目标：让 `hoo66.top` 指向新后端，并统一账号为稳定的 `xu / si`。旧网站继续留在 `chat.huhuhu.top`，不要覆盖。

## 重要原则

- 不再使用旧后端的 `alice / bob`。
- 生产环境账号 username 必须固定为 `xu / si`，后续不要改。
- 旧 App token 会在新后端下失效，这是正常的；重新登录一次即可。
- 如果要保留旧历史，需要先做 `alice -> xu`、`bob -> si` 的数据库迁移。否则新后端会从空库开始。

## 首次部署

在服务器上：

```bash
cd /opt
git clone https://github.com/hugxu0/couplechat-ios.git couplechat-ios
cd /opt/couplechat-ios
git checkout codex/new-backend-ios-media

cd server
cp .env.production.example .env
nano .env
```

必须修改：

```env
TOKEN_SECRET=用 openssl rand -hex 32 生成
COUPLECHAT_ACCOUNTS=xu|小旭|真实密码|🐶;si|小偲|真实密码|🐰
PUBLIC_BASE_URL=https://hoo66.top
```

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
```

`/api/accounts` 必须返回：

```json
[
  { "username": "xu", "name": "小旭", "avatar": "🐶" },
  { "username": "si", "name": "小偲", "avatar": "🐰" }
]
```

然后在 iPhone 上重新登录 `xu / si`。

## 更新部署

```bash
cd /opt/couplechat-ios
git fetch
git checkout codex/new-backend-ios-media
git pull
cd server
npm ci
npm run build
pm2 restart couplechat-server
```

## 数据备份

至少备份：

```text
server/.data/couplechat.sqlite
server/uploads/
```

简单备份命令：

```bash
mkdir -p /opt/backups/couplechat
tar -czf /opt/backups/couplechat/couplechat-$(date +%F-%H%M).tar.gz .data uploads
```
