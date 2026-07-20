# 服务器、部署与恢复

本文统一记录生产拓扑、服务器职责、健康检查、发布、备份、恢复、回滚和维护者交接。当前生产 `RELEASE`、schema 和最后核验结果只在 [PROJECT.md](PROJECT.md) 更新。

## 安全边界

- 生产连接、migration、数据库写入、Nginx reload、备份删除和部署都必须先得到明确授权。
- 真实公网 IP、SSH 私钥、密码、数据库 URL、代理 key、AI/Bark key、证书私钥和备份内容只存在于仓库外私有 runbook。
- 私有连接值只能用于当前受信进程，不能复制到 Git、日志、Issue、artifact 或回答。
- 服务端发布只接受完整 commit/tag 的 `server/` 子树，禁止 moving `main`、`latest` 和来源不明的远程脚本。

## 私有 VPS 资料地图

本仓库只记录公开安全的拓扑、路径和操作边界。受信 Windows 工作站上的私有事实源固定在 `D:\Desktop\01_开发项目\VPS运维`；该路径不含凭据，主机、密钥和服务值仍只从目录内对应私有文档读取：

```powershell
$VpsRoot = 'D:\Desktop\01_开发项目\VPS运维'
if (-not (Test-Path -LiteralPath $VpsRoot -PathType Container)) {
  throw "私有 VPS 资料不存在，请向用户确认当前位置"
}
```

其中 `racknerd/` 对应美国唯一可写源站，`RFCHost/` 对应日本公开入口。接手时按任务最小读取：

| 任务 | 私有资料 |
|---|---|
| 任何 VPS 工作 | 对应主机的 `00-阅读入口.md` |
| 确认主机身份、资源、端口、服务、Docker、备份 | `01-服务器总览.md` |
| Nginx、TLS、证书、443 分流、站点 | `03-Nginx与网站.md` |
| 排障或修改配置 | `05-运维排障手册.md` |
| IP、SSH 登录、跨主机 key、origin 校验值 | `08-凭据与密钥清单.md`，仅在得到连接授权后读取 |
| 美国源站恢复、重建或迁移；日本中转重建 | `09-灾备与恢复.md` |

`02-*`、`04-*` 和 `07-*` 分别属于 Xray、订阅和 DNS；CoupleChat 日常开发不需要读取或修改。不得把 `08-*`、订阅文件、扫描报告、数据库 dump 或聊天记录复制进仓库、共享终端日志或 AI 回答；自动化工具也不能直接用 `Get-Content` 把凭据文件回显出来。若私有资料与服务器实时只读结果不一致，以实时结果定位事实，并在获准修改后更新对应私有状态文档。

## 当前拓扑

```text
iPhone / iPad
  → https://hoo66.top:443
  → 日本 Nginx stream
  → 日本 127.0.0.1:8444 HTTPS edge
  → 私有 origin 链路
  → 美国 Nginx stream
  → 美国 127.0.0.1:10443 HTTPS origin
  → 美国 127.0.0.1:3000 Fastify + Socket.IO
  → 美国 127.0.0.1:5432 PostgreSQL
```

客户端永远只使用 `hoo66.top`，不能直接连接 origin。日本 edge 注入私有代理 header；美国 origin 缺少或不匹配时返回 `403`。公网 443 与其他私有服务共享 Nginx stream，修改 CoupleChat 配置前必须在私有 runbook 核对现有 SNI 路由。

## 两台服务器职责

| 项目 | 日本入口 | 美国源站 |
|---|---|---|
| 角色 | 公开 TLS 入口、HTTP/WebSocket 中转；不运行 CoupleChat | 唯一可写应用与数据主机 |
| HTTPS 回环 | `127.0.0.1:8444` | `127.0.0.1:10443` |
| CoupleChat Node | 不安装、不保留容器 | `127.0.0.1:3000` |
| PostgreSQL | 未安装，不保留 CoupleChat 数据目录 | `127.0.0.1:5432/couplechat` |
| 项目目录 | 不保留 | `/opt/couplechat-ios/server` |
| uploads | 不保留 | `/opt/couplechat-ios/server/uploads` |
| 日常发布 | 禁止 | 固定 SHA 的 `server/` 包 |

日本只转发流量，没有 CoupleChat 项目、数据库、媒体、容器、Docker/PostgreSQL 软件包或冷恢复包，不能作为备用源站。生产数据只存在于美国事实源和经验证的离机备份。美国 `127.0.0.1:8080` 是 `sub2api`，日本 `127.0.0.1:18080` 是到它的 SSH 隧道入口；两者都不属于 CoupleChat Node 生产端口。

## VPS 上现有内容

以下是私有 runbook 的当前角色摘要，不代替连接后的 `free -h`、`df -h`、`systemctl` 和主机相关的运行时检查；`docker ps` 只适用于仍运行 Docker 的美国源站。资源数字会变化，操作前必须重新只读核验。

### 美国 RackNerd

- Ubuntu 24.04 x86_64 KVM；私有记录约为 2.4 GiB 内存、39 GiB 根磁盘；最近只读核验为 11 GiB 已用、26 GiB 可用（29%）。资源会变化，操作前重新检查。
- 当前内核为 `6.8.0-136-generic`；官方系统更新和必要重启已完成，`fwupd`、孤立依赖与废弃旧内核已移除，失败单元、待更新、可自动移除包和重启要求均为零。
- `nginx`、`xray`、`docker`、`postgresql`、`fail2ban` 常驻；PostgreSQL 16 是 CoupleChat 唯一生产数据库。
- Docker 中除 `couplechat-server` 外还有 KG、Beszel agent/server、Neo4j、`sub2api` 和 `sub2api-redis`。不要使用会影响全部容器的批量停止、prune 或重建命令。
- 公网 `443` 由 Nginx stream 在 Xray 与 HTTPS 站点之间按 SNI 分流；CoupleChat origin 再反代到 `127.0.0.1:3000`。
- Neo4j 端口在私有记录中仍有公网暴露风险，但它不属于 CoupleChat；未经单独授权不得改防火墙、Neo4j 或依赖它的服务。
- CoupleChat 备份在本机保留 v3 基线，并同步到私有 B2 离机存储；不要输出 bucket、remote 或凭据。

关键位置：

| 路径 | 内容与边界 |
|---|---|
| `/opt/couplechat-ios/server` | CoupleChat 发布目录、Compose、`RELEASE`、`.env` 和 `uploads/`；`.env` 只能检查权限，不能输出 |
| `/opt/couplechat/bin/deploy-server`、`/opt/couplechat/incoming` | 当前固定 SHA 发布入口与临时收包目录；`incoming` 应保持为空，不能与旧的 `/opt/couplechat-ios/incoming` 混淆 |
| `/var/backups/couplechat` | 当前 v3 日备份与恢复验证基线；数据发布前核验 metadata、SHA-256 和 `RESTORE-VERIFIED` |
| `/root/backup` | 备份脚本、日志及其他服务备份；普通代码发布不调用完整备份 |
| `/etc/nginx/stream-conf.d/00-443-split.conf` | 公网 443 的 SNI 分流，修改会同时影响 Xray 和全部 HTTPS 站点 |
| `/etc/nginx/sites-available/chat` | CoupleChat 私有 origin 站点；含私有校验依赖，不能直接打印配置全文 |
| `/root/kg`、`/root/beszel`、`/opt/sub2api` | 其他共享服务的 Compose 目录，不属于 CoupleChat 发布包 |
| `/root/.ssh/config` | 到日本的 `rfchost` 主机别名；私钥和值仍以私有凭据清单为准 |

### 日本 RFCHost

- Ubuntu 24.04 x86_64 KVM；私有记录约为 458 MiB 内存、9.9 GiB 根磁盘，资源明显小于美国源站；最小化清理和系统更新后只读核验为 2.3 GiB 已用、6.8 GiB 可用（25%），约 146 MiB 内存已用、311 MiB 可用。资源会变化，操作前重新检查。
- `nginx`、`xray`、`fail2ban`、`sub2api-tunnel` 为 `active/enabled`，`ssh.socket`、`certbot.timer` 和标准 `logrotate.timer` 正常；Docker、PostgreSQL、Node.js、PM2 软件包或运行时均不存在。
- 日本不保留 `couplechat-server` 容器、镜像、Docker/containerd 运行时目录、项目目录、PostgreSQL 数据目录、uploads 或恢复归档；无用硬件服务及其孤立依赖也已卸载。
- 公网 `443` 同样由 Nginx stream 分流；`hoo66.top` 的 HTTPS 回环处理订阅静态路径，其余请求跨国转发到美国私有 origin。
- `127.0.0.1:18080` 是独立 `sub2api` SSH 隧道的本地入口，不属于 CoupleChat；对应 Nginx 站点和隧道服务必须一起保留。
- `certbot.timer` 负责日本公开站点证书续期。修改站点前必须备份、`nginx -t`、reload 后验证公开入口。

关键位置：

| 路径 | 内容与边界 |
|---|---|
| `/etc/nginx/stream-conf.d/00-sni-split.conf` | 日本公网 443 的 Xray/HTTPS 分流 |
| `/etc/nginx/sites-available/hoo66.top` | 公开入口、订阅静态路径和到美国 origin 的反代；不能泄露私有 header 值 |
| `/etc/nginx/sites-available/sub2api`、`/etc/systemd/system/sub2api-tunnel.service` | 独立 `sub2api` 站点和到美国的 SSH 本地转发；不属于 CoupleChat |
| `/etc/letsencrypt/live/hoo66.top` | 公开入口证书；严禁读取或复制 `privkey.pem` |
| `/root/codex-sub-path.txt` | 当前私有订阅路径，权限 `600`；只能用于本机检查，不得输出内容 |
| `/root/codex-backups` | 空的 Nginx 配置备份目录，权限 `700`；不存放 CoupleChat 数据或归档 |
| `/root/.ssh/config` | 到美国的 `racknerd` 主机别名；只在已登录日本且任务需要时使用 |

### 清理后的残留边界

- 两台机器的 `/opt/couplechat-ios/server/tests` 均已不存在；运行容器只挂载 `.data` 和 `uploads`，不会从宿主机读取测试目录。
- 美国旧 `/opt/couplechat-ios/incoming`、临时 Codex 发布缓存和旧配置归档已清除；当前 `/opt/couplechat/incoming` 是发布脚本使用的目录，保持为空。
- 美国旧 Filebrowser 容器、项目目录和 Nginx 站点均不存在；`8080` 当前由 `sub2api` 使用，不能按旧文档恢复或覆盖。
- 日本 CoupleChat 项目目录、旧容器/镜像、Docker/PostgreSQL/Node.js/PM2 软件包与运行时目录、PostgreSQL 数据目录、uploads、恢复脚本、数据库 dump、源码归档、Claude/Oh My Zsh 管理目录和冷回滚备份均已清除；订阅检查依赖的私有路径文件保留为 `600`。
- 日本重复的 Xray 专用 logrotate timer 已移除，只保留会包含 `/etc/logrotate.d` 的系统标准 timer；日志轮转实跑成功且系统无失败单元。
- 清理后美国本机 `/live`、`/health`、`/ready`、公开入口、数据库和备份 SHA-256 均通过；Docker 构建缓存为 `0 B`，核心服务无启动错误。日本公开入口、订阅、`sub2api`、Nginx 和 Xray 中转状态均通过核验，系统更新和孤立依赖均为零。

## 代理约束

日本 edge 和美国 origin 都必须保留：

- HTTP/1.1 与 WebSocket `Upgrade` / `Connection`；
- `client_max_body_size 80m`；
- `proxy_request_buffering off` 与 `proxy_buffering off`；
- 至少 300 秒读写超时；
- 正确的 TLS SNI、公开 Host 和 `X-Forwarded-*`；
- origin 私有代理 key 校验。

仓库 `server/deploy/` 中的 Nginx 文件只是不含秘密的模板，不能直接覆盖生产配置。修改前先备份，运行 `nginx -t`，再 reload 并执行三层健康检查。

## 接手与连接

维护者需要生产信息时，按以下顺序：

1. 执行根 `AGENTS.md` 的开工检查。
2. 阅读 [PROJECT.md](PROJECT.md)、[ARCHITECTURE.md](ARCHITECTURE.md) 和本文。
3. 从 `D:\Desktop\01_开发项目\VPS运维` 读取目标主机 `00-*`、`01-*`；涉及 Nginx、故障或恢复时继续读取对应模块。
4. 只有获得明确生产连接授权后才读取 `08-凭据与密钥清单.md`，确认目标 IP、登录方式和 key 位置。
5. 先以 `BatchMode=yes` 做无交互只读连接；确认身份后执行 preflight。日本默认只读，美国也不能因“已连接”而自动获得写权限。

### 从受信 Windows 工作站连接

当前私有 runbook 使用 `root` 和本机 Ed25519 key。目标 IP 必须在当前进程中从对应 `01-*` 或 `08-*` 读取，不写入脚本、仓库或回答：

```powershell
$VpsRoot = 'D:\Desktop\01_开发项目\VPS运维'
$Provider = 'racknerd' # 日本使用 RFCHost

Get-Content -LiteralPath (Join-Path $VpsRoot "$Provider\00-阅读入口.md")
Get-Content -LiteralPath (Join-Path $VpsRoot "$Provider\01-服务器总览.md")
# 获得生产连接授权后，才读取 08-凭据与密钥清单.md

$Target = Read-Host '输入私有清单中的目标 IP（不会保存）'
$Key = Join-Path $HOME '.ssh\id_ed25519'
if (-not (Test-Path -LiteralPath $Key -PathType Leaf)) {
  throw "SSH 私钥不存在，请检查受信工作站，不要改用仓库内文件"
}

$KnownHost = ssh-keygen -F $Target 2>$null
if (-not $KnownHost) {
  throw "known_hosts 中没有该主机；停止并人工核对指纹"
}
Remove-Variable KnownHost
ssh -i $Key -o IdentitiesOnly=yes -o BatchMode=yes `
  -o StrictHostKeyChecking=yes -o ConnectTimeout=15 `
  "root@$Target" 'hostname; id -u; date -u; uptime'
```

`ssh-keygen -F` 没有结果或指纹变化时停止，不使用 `accept-new`，通过用户或供应商控制台核对指纹。连接失败时依次检查 key 是否存在、Windows ACL、`known_hosts`、私有清单和本机网络；可在本机使用 `ssh -vvv` 排障，但不能把完整输出复制进仓库或回答。不得关闭 `StrictHostKeyChecking`，不得把密码写进命令行、脚本或环境变量，也不得扫描公网地址。

若私有清单明确允许密码登录，只能在用户授权后交互输入。`BatchMode` 失败不代表可以自行切换认证方式。

### 两台 VPS 之间连接

两台服务器的 root SSH 配置中存在互访别名：

```bash
# 已登录美国 RackNerd 后
ssh rfchost

# 已登录日本 RFCHost 后
ssh racknerd
```

互访别名只用于获准的诊断、备份或灾备操作，不能绕过首次目标确认，也不能用来复制 `.env`、数据库、订阅配置或私钥。登录后先运行 `hostname; id -u; date -u`，再按主机角色检查服务；不要仅凭终端提示符判断当前机器。

## 只读 preflight

### 美国源站

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

schema 只能在服务器本机或受限只读连接中核验，不能从公开健康接口推断：

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

### 日本入口

```bash
set -eu
nginx -t
systemctl is-active nginx xray fail2ban
curl -kfsS https://127.0.0.1:8444/live \
  -H 'Host: hoo66.top' >/dev/null
```

日本 preflight 只确认 Nginx、证书和转发，不启动 Node、PostgreSQL 或写数据。

## 三层健康检查

1. **美国本机**：`http://127.0.0.1:3000/live|health|ready`。
2. **私有 origin**：使用 root-only proxy key 请求 origin `/health`；不带 key 返回 `403` 是预期。
3. **公开入口**：`https://hoo66.top/live|health|ready`，并检查固定账号列表、Socket.IO 和需要时的上传。

只有三层全部通过才能宣布发布成功。

## 普通代码发布

适用于无 migration、数据修复、媒体目录变化或不兼容协议变化的服务端代码。它不停止写入、不运行 migrator，也不为每次发布重复完整备份恢复。

在工作树干净、`HEAD` 已推送且精确等于远程分支后，从仓库根目录运行：

```powershell
.\server\deploy\publish-server.ps1 -SshTarget '<private-ssh-alias>'
```

脚本负责：

1. 确认固定 SHA 和干净工作树；
2. 本机执行一次 `npm run check`；
3. 只归档 `server/` 并校验 SHA-256；
4. 在美国确认当前 `RELEASE`、schema、环境文件、磁盘、容器和恢复基线；
5. 构建固定 SHA 镜像，以 `RUN_MIGRATIONS=false` 重建唯一 writer；
6. 执行三层健康、账号列表和 Socket.IO 检查；
7. 全部通过后同步源码并最后写入 `RELEASE`；失败时恢复旧镜像和旧源码。

服务器固定入口为 `/opt/couplechat/bin/deploy-server`。普通发布保留当前镜像和一个回滚镜像，不创建或删除备份。

## 数据变更发布

只有 migration、数据修复、媒体格式/目录变化、不兼容 Sync/协议变化、恢复或源站迁移才走此路径：

1. 明确停止写入或 quiesce 方法；
2. 新建 PostgreSQL 与 uploads 一致备份并记录 SHA-256；
3. 在隔离临时库完成真实恢复验证；
4. 按兼容顺序运行独立 migrator，再启动候选版本；
5. 完成三层健康检查；
6. 记录新的 `RELEASE`、schema、备份和恢复证据。

发布包不能包含 `.env`、数据库、uploads、`.data`、iOS 源码或 Apple 签名资料。

## 备份

- 定时任务生成 PostgreSQL dump、uploads 归档、metadata、SHA-256 和离机副本。
- 恢复验证在随机临时库进行；普通代码发布只检查现行基线存在。
- 当前只接受备份 `format_version=3`；旧格式不能作为恢复基线。
- `RESTORE-VERIFIED` 只有在真实恢复、schema/表计数、关键序列和媒体抽样完成后才有效。
- 备份不可读、哈希不匹配或 uploads 不完整时，禁止数据变更发布和恢复。
- 清理前必须确认现行基线和兼容回滚镜像存在；不能删除唯一可用备份或正在使用的数据。

离机供应商、容量、最近批次和恢复演练结果只能在私有 runbook 核验，不写入公开仓库。

## 回滚与源站恢复

- schema 兼容时，切回保留的回滚镜像并重新执行三层健康检查。
- schema 已变化或迁移失败时，停止写入，恢复同一批次数据库与 uploads，再启动兼容镜像。
- 应用镜像回滚不等于数据库回滚，不能只重新部署旧 SHA。

日本没有 CoupleChat 项目或数据，不能执行冷切换。美国不可恢复时，只能从经验证的离机备份恢复到美国修复后的主机或另一个明确批准的新源站；恢复完成前，日本保持纯中转状态。

## 首次安装（美国源站）

首次安装不属于日常发布。美国源站的 Ubuntu、Docker/Compose、PostgreSQL、Nginx、证书、环境文件、uploads 和备份目录由仓库外私有 runbook 准备；日本中转重建只恢复 Nginx、Xray、证书、订阅静态文件和 origin 转发配置。完成后回到固定 SHA 的普通发布入口。

## 操作结束报告

每次生产操作必须记录：

- 源码 commit、生产 `RELEASE` 和 schema；
- 读取或修改了哪台服务器；
- 美国本机、私有 origin 和公开入口结果；
- 是否执行 migration、备份、恢复、数据修复或源站迁移；
- 是否修改数据库、Nginx、证书、密钥、uploads 或设备状态；
- 尚未完成的真机、离机备份和安全核验。

如果主机角色、服务、端口、Nginx、证书、备份或恢复状态发生变化，还要更新 `D:\Desktop\01_开发项目\VPS运维/<provider>/` 中对应的 `01-*`、`03-*`、`05-*` 或 `09-*` 当前状态；仓库的公开生产结论只更新 [PROJECT.md](PROJECT.md)。凭据变化只更新私有 `08-*`，不得进入 Git。

无法证明的项目写“未验证”，不能写“应该正常”。
