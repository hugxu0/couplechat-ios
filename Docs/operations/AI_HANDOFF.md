# AI 接手与服务器连接手册

本文是公开仓库中的接手协议，不是凭据文件。它说明未来的 AI 或维护者应在哪里找到私有连接资料、如何建立只读 SSH 会话，以及两台生产服务器分别负责什么。

## 安全边界

本项目是公开 GitHub 仓库，因此以下内容永远不进入 Git：

- 真实公网 IP、SSH 私钥、密码、代理 key、数据库 URL；
- Cloudflare、DNS、证书私钥、Bark/AI key；
- 数据库 dump、uploads、设备 UDID 和 Apple 签名资料。

公开仓库只记录拓扑、端口、目录、命令模板和验收边界。真实连接值由操作者在受信工作区提供给 AI。本机当前的私有资料目录是：

```text
D:\Desktop\vps\
  racknerd\   # 美国唯一可写源站
  RFCHost\    # 日本公网入口与冷灾备
```

未来工作区不一定使用这个 Windows 路径。如果目录不存在，应向项目所有者索取同等结构的仓库外私有资料，不能猜测地址，也不能从 Git 历史寻找旧 IP。

## AI 接手顺序

1. 在仓库根目录执行根 `AGENTS.md` 的开工检查。
2. 阅读 `Docs/README.md`、`Docs/current/PROJECT.md`、`Docs/current/KNOWN_ISSUES.md`。
3. 阅读 [PRODUCTION_TOPOLOGY.md](PRODUCTION_TOPOLOGY.md)、[DEPLOYMENT.md](DEPLOYMENT.md) 和本文件。
4. 在仓库外读取两套私有资料的入口文档：

   ```text
   D:\Desktop\vps\racknerd\00-阅读入口.md
   D:\Desktop\vps\racknerd\01-服务器总览.md
   D:\Desktop\vps\racknerd\03-Nginx与网站.md
   D:\Desktop\vps\racknerd\05-运维排障手册.md
   D:\Desktop\vps\racknerd\09-灾备与恢复.md

   D:\Desktop\vps\RFCHost\00-阅读入口.md
   D:\Desktop\vps\RFCHost\01-服务器总览.md
   D:\Desktop\vps\RFCHost\03-Nginx与网站.md
   D:\Desktop\vps\RFCHost\05-运维排障手册.md
   D:\Desktop\vps\RFCHost\09-灾备与恢复.md
   ```

5. 只有在用户明确授权生产操作后，才读取私有凭据清单并连接服务器。凭据清单的内容只能用于当前进程，不能复制到仓库、日志、Issue 或回答。
6. 先做两台服务器的只读 preflight，再决定是否需要美国源站写操作。日本默认只读。

## SSH 连接模板

私有入口文档或用户提供的受信 SSH 配置是连接值的唯一来源。变量必须在本机临时设置，不能写入脚本或提交：

```powershell
$User = '<private-runbook SSH user>'
$Host = '<private-runbook host or SSH alias>'
$Key  = '<private key path outside repository>'

ssh -i $Key `
  -o BatchMode=yes `
  -o IdentitiesOnly=yes `
  -o StrictHostKeyChecking=yes `
  -o ConnectTimeout=15 `
  "$User@$Host" 'hostname; id -u; date -u'
```

如果私有资料已经配置了 SSH alias，优先使用 alias，不要把 alias 展开成公网 IP 写入仓库：

```powershell
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes `
  -o ConnectTimeout=15 <private-ssh-alias> 'hostname; id -u'
```

连接失败时只能检查本机私钥权限、`known_hosts` 指纹、私有资料中的主机状态和网络；不能关闭 `StrictHostKeyChecking`，不能把密码粘贴到命令行，也不能扫描公网地址。

## 两台服务器的职责与配置

| 项目 | 日本 RFCHost | 美国 RackNerd |
|---|---|---|
| 角色 | `hoo66.top` 公网入口、Nginx stream/HTTPS 中转、冷灾备 | CoupleChat 唯一可写应用与数据源 |
| 应用 Node | 不运行 CoupleChat Node | Docker 中运行 Fastify + Socket.IO |
| Node 回环端口 | 不适用 | `127.0.0.1:3000` |
| CoupleChat HTTPS 回环 | `127.0.0.1:8444` | `127.0.0.1:10443` |
| PostgreSQL | 停用，仅保留冷数据 | PostgreSQL 16，`127.0.0.1:5432/couplechat` |
| 项目目录 | `/opt/couplechat-ios/server` 仅作冷回滚资料 | `/opt/couplechat-ios/server` |
| 媒体目录 | 冷数据 | `/opt/couplechat-ios/server/uploads` |
| 备份目录 | 私有灾备资料定义 | `/var/backups/couplechat` |
| 日常发布 | 禁止 | 只发布固定 commit 的 `server/` |

美国 `8080` 属于其他服务，不能拿来替代 CoupleChat 的 Node 端口。公网客户端只能访问 `https://hoo66.top`，不能改成 origin 域名。

## 只读 preflight

### 美国 RackNerd

```bash
set -eu
test -d /opt/couplechat-ios/server
test -f /opt/couplechat-ios/server/RELEASE
stat -c '%a %U:%G' /opt/couplechat-ios/server/.env
sed -n '1p' /opt/couplechat-ios/server/RELEASE
curl -fsS http://127.0.0.1:3000/live >/dev/null
curl -fsS http://127.0.0.1:3000/health >/dev/null
curl -fsS http://127.0.0.1:3000/ready >/dev/null
docker inspect couplechat-server --format \
  'status={{.State.Status}} restarts={{.RestartCount}} image={{.Config.Image}}'
```

schema 只能在服务器本机或受限只读连接中核验，不从公开健康接口推断：

```bash
docker exec couplechat-server node -e '
const {Client}=require("pg");
(async()=>{const c=new Client({connectionString:process.env.DATABASE_URL});
await c.connect();
const r=await c.query("select max(version)::text from schema_migrations");
console.log(r.rows[0].max);
await c.end()})().catch(()=>process.exit(2));
'
```

### 日本 RFCHost

```bash
set -eu
nginx -t
curl -kfsS https://127.0.0.1:8444/live \
  -H 'Host: hoo66.top' >/dev/null
```

日本检查的目标是确认 Nginx、证书和转发仍在工作，不是启动 Node、PostgreSQL 或修改数据。不得在日本启动第二个可写 CoupleChat 实例。

## 生产写操作前的硬门槛

任何生产写操作都必须先明确记录：

1. 目标服务器：美国源站，或经批准的日本冷切换；
2. 完整 commit/tag；禁止 `main`、`latest` 或 moving branch；
3. 当前 `RELEASE`、schema 和容器 image；
4. 回滚 image、数据库、uploads 和密钥的边界；
5. 三层健康检查结果。

普通代码发布顺序是：

```text
固定 server-only 包
  → SHA-256 校验
  → 构建或复用镜像
  → 仅重建美国 writer
  → 本机 / origin / hoo66.top 健康检查
  → 最后写 RELEASE
```

只有 migration、数据修复、媒体结构变化、同步协议不兼容或恢复/冷切换，才额外记录 quiesce、备份 SHA-256、`RESTORE-VERIFIED` 和独立 migrator，并按 [DEPLOYMENT.md](DEPLOYMENT.md) 的数据变更路径执行。

当前仓库仍没有真正实现的 `/opt/couplechat/bin/deploy-server` 一键入口；在它实现前，AI 必须按 [DEPLOYMENT.md](DEPLOYMENT.md) 的人工步骤操作，不能自行拼接一条“自动部署命令”。

## 接手结束时必须交付

- 当前源码 commit、服务端生产 `RELEASE` 和 schema；
- 哪台服务器被读取或修改；
- 三层健康结果；如果执行数据变更路径，再附备份/恢复验证；
- 是否修改了数据库、Nginx、证书、密钥或设备状态；
- 尚未完成的真机、离机备份、rerun attempt 和安全任务。

任何一项无法证明时，写“未验证”，不要写“应该正常”。
