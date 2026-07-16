# 服务端部署、备份与恢复

> 本文只负责服务端。iOS unsigned IPA、免费账号签名与侧载见 [IOS_SIDELOAD.md](IOS_SIDELOAD.md)，网络链路见 [PRODUCTION_TOPOLOGY.md](PRODUCTION_TOPOLOGY.md)。

## 当前结论

- 正常发布只更新美国 RackNerd，不更新日本 RFCHost。
- 生产目录为 `/opt/couplechat-ios/server`，Node 监听 `127.0.0.1:3000`，PostgreSQL 16 监听 `127.0.0.1:5432`。
- 日本是入口和冷灾备；禁止与美国同时启动可写后端。
- 当前源码要求 schema v31；生产真实版本不写入公开仓库。部署前必须现场读取 `RELEASE` 与 `schema_migrations`，不能根据旧文档或公开健康状态猜测差异。
- 仓库已有版本感知的备份、真实临时库恢复验证和健康检查等组件；本次已在真实生产副本完成一次 quiesced v31 备份、临时库恢复验证和固定 SHA 切换。**目前仍没有经过端到端验证的一键首装/升级入口，也没有离机副本自动确认**。下文把已实测人工流程和待实现的一键接口分开描述。

未经用户明确授权，不执行生产部署、migration、Nginx reload 或数据恢复。

## 单仓库如何一键部署

单仓库不会让服务端发布包含 iOS 文件。目标流水线只归档 `server/` 子树：

```text
精确 server-vX.Y.Z tag / commit
  → server test + build + migration smoke
  → server-only tar.gz
  → RELEASE-METADATA.json + SHA256SUMS
  → GitHub Release
  → 美国主机部署入口下载并验证
  → 备份 → 候选镜像 → migration → 切换 → 三层健康检查
```

计划中的唯一主机命令形态：

```bash
sudo /opt/couplechat/bin/deploy-server server-vX.Y.Z
```

该命令尚未实现；在对应脚本、release workflow 和集成测试落地前，不能把上面命令写进自动化或实际执行。

### 一键入口必须完成

1. 获取全局 deploy lock，拒绝并发发布；
2. 只接受不可变 tag 或完整 commit，禁止下载 moving `main`；
3. 下载 server-only 包并校验 SHA-256、metadata、Node/schema 兼容范围；
4. 检查 `.env` 权限、`PORT=3000`、数据库连接、磁盘空间及 uploads/data 可写性；
5. 强制停写后创建 PostgreSQL、uploads 和必要配置的发布前备份，完成静态校验、随机临时库真实恢复和版本感知的全表计数比对，并确认加密离机副本；`best_effort` 不得通过 migration 门禁；
6. 在候选目录构建镜像，确认 `dist/migrate.js` 存在；
7. 短暂停写，使用独立 migrator 执行只前进 migration；Web 进程保持 `RUN_MIGRATIONS=false`；
8. 激活候选镜像，写入完整 SHA、tag、schema 和部署时间；
9. 依次验证美国本机、带 key 的私有 origin、公开 `hoo66.top`，再验证 WebSocket 与上传；
10. 失败时按 schema 兼容范围决定回滚应用还是恢复数据库+uploads；自动清理候选目录并释放 lock。

发布脚本不得把 Apple/iOS 文件复制到服务器，也不得以 root 身份执行未经校验的远程脚本。

## 首次安装与日常升级必须分开

### 首次安装前置条件

- Ubuntu 24.04、Docker/Compose、PostgreSQL 16、Nginx 和证书已由主机运维准备；
- 数据库与角色已创建，且数据库只监听回环/受控网络；
- `/opt/couplechat-ios/server/.env` 单独创建并设为 `0600`；
- `uploads/`、`.data/` 与备份目录由运行用户可写。bind mount 会覆盖镜像内权限，不能只依赖 Dockerfile 的 `chown`；应从镜像现场读取 `node` UID/GID 后设置宿主目录并做写入探针；
- 美国 origin Nginx 和日本 edge Nginx 已按 [PRODUCTION_TOPOLOGY.md](PRODUCTION_TOPOLOGY.md) 配置并验证；
- 已有一份可恢复的空库/初始化前备份，以及仓库外的密钥备份。

首次安装不能调用“当前版本的备份脚本”作为前置，因为目标目录尚不存在。首装脚本应自带 bootstrap、检查环境、创建目录、构建初始镜像、运行 migration、创建固定账号并完成三层健康检查。

### 当前必需环境

```env
NODE_ENV=production
HOST=127.0.0.1
PORT=3000
PUBLIC_BASE_URL=https://hoo66.top
DATABASE_URL=postgres://<user>:<password>@127.0.0.1:5432/couplechat
TOKEN_SECRET=<至少32字节的随机密钥>
RUN_MIGRATIONS=false
COUPLECHAT_ACCOUNTS=xu|<display-name>|<password>|<avatar>;si|<display-name>|<password>|<avatar>
```

实际秘密值只在服务器 `.env`/root-only 文件中。当前代码每次生产启动仍要求 `COUPLECHAT_ACCOUNTS` 同时包含 `xu/si`，但已有账号不会被环境变量自动更新；密码轮换需要后续实现显式管理命令。不要按旧文档在首次启动后删除该变量。

仓库当前 `.env.production.example`、Compose、Dockerfile 和健康检查已经把生产默认值统一为 `3000`，配置层面的端口冲突已修复。生产 `.env` 仍必须显式写入 `PORT=3000`，未来部署 preflight 也必须拒绝其他值；首次安装与一键升级入口尚未实现，见 [OPS-001/OPS-004](../current/KNOWN_ISSUES.md)。

## 当前人工发布边界

一键脚本完成前，每次人工发布都必须逐项记录证据，不能复制一段命令后直接宣布成功。

### 1. 固定源码并验证

```powershell
git switch main
git pull --ff-only origin main
git status --short --branch
$Release = (git rev-parse HEAD).Trim()

cd server
npm ci
npm test
npm run build
cd ..
```

必须确认目标 SHA 的 CI 通过。工作树有未提交修改时不得用 `git archive HEAD` 冒充包含这些修改。

### 2. 创建 server-only 候选包

```powershell
$Short = $Release.Substring(0, 12)
New-Item -ItemType Directory -Force build-artifacts | Out-Null
git -c core.autocrlf=false archive --format=tar.gz `
  --output="build-artifacts/server-$Short.tar.gz" HEAD:server
Get-FileHash "build-artifacts/server-$Short.tar.gz" -Algorithm SHA256
```

候选包不包含 `.env`、uploads、`.data`、数据库或 iOS 文件。上传到美国后先解压到新的候选目录，不能直接覆盖 `/opt/couplechat-ios/server`。具体切换前要现场核对现有 Compose、镜像标签、bind mount 和主机备份脚本；当前仓库尚未提供安全的通用 copy/paste 切换命令。

### 3. 发布前备份

当前源码已经修复 [OPS-005/OPS-006](../current/KNOWN_ISSUES.md) 所记录的表清单漂移和“先删旧、后建新”问题。本次真实生产演练使用 root-only `CREATEDB`/`pg_signal_backend` 恢复校验角色和服务器外部 quiesce hook 成功完成；目标 Linux 失败注入仍待补，也不会自动复制或确认离机副本。因此脚本可以作为人工流程的组成部分，**不能单独充当自动发布门禁**。

当前脚本契约：

- `backup-table-policy.sh` 是备份与恢复共用的唯一表策略。它按 schema 版本覆盖 v1–v31 migrations 中应存在的全部持久化表；遇到缺表、清单异常或高于策略上限的 schema 会直接失败，不能静默跳过 Memory 或其他业务表。
- `backup-production.sh` 先生成 PostgreSQL custom dump、全表计数、uploads 归档/manifest 和 metadata，再校验固定文件哈希、dump/归档可读性。只有 daily 以及周日 weekly 完成本地校验并原子发布后才执行保留期 prune；这里的“本地校验”不是实际恢复。
- 当前备份格式为 v3；目录名和 metadata 使用带随机后缀的不可变 `backup_id`，轮转只按其中的 UTC 创建时间判龄，不会因为后来写入验证标记而延长保留期。
- 未经过恢复验证的新备份在轮转时会至少保留一份旧成品；daily/weekly 各自最后一份有效的 `quiesced + RESTORE-VERIFIED` 永远保留，恢复验证过的 `best_effort` 备份不能替代它。开始新备份前只会清理超过安全年龄的 `.partial-*` 半成品，不会提前删除已发布备份。
- `verify-backup.sh` 使用 `VERIFY_DATABASE_URL` 指向的受限 `CREATEDB` 账号创建随机临时库，真实恢复 dump，核对 schema、策略要求的全部表计数、`message_server_seq_seq`/`sync_event_seq` 的状态与数据上界，并对媒体归档抽样校验。只有这些检查和临时库删除均成功后才原子写入格式 v2 的 `RESTORE-VERIFIED`。
- `RESTORE-VERIFIED` 会绑定当前 `SHA256SUMS` 的 SHA-256；而 `SHA256SUMS` 覆盖 dump、uploads、metadata 和固定配置快照。标记本身不参与原始归档哈希，仍不是签名、离机副本回执或生产恢复演练证明，不能仅凭标记存在宣布备份可用。
- 旧备份格式 v2 只能做降级验证：即使已有表计数和真实恢复通过，也以退出码 `3` 结束且不写新标记，因为它不能证明 v3 的全表与序列契约。
- 源码版本优先读取 root-owned、非符号链接且权限为 `0400/0600` 的 `server/RELEASE` 完整 SHA；仅在本地 Git 仓库可证明完整 SHA 时回退为 `git`，否则明确记录 `unknown`，不得伪造版本证据。
- 未配置 quiesce hook 时，备份 metadata 会记录 `consistency_mode=best_effort`。即使该备份随后通过恢复验证，也不能证明 dump 与 uploads 来自同一停写点，因而不能作为 migration 发布门禁。

正式发布前还必须人工满足：

1. 进入短暂停写，设置 `BACKUP_REQUIRE_QUIESCE=1` 并确认最终 metadata 为 `consistency_mode=quiesced`；
2. 对新原子发布的备份运行 `verify-backup.sh`，使用隔离的受限恢复账号，不覆盖生产库；
3. 核对新生成的有效 `RESTORE-VERIFIED`，同时确认之前至少一个已恢复验证版本仍存在；
4. 在私有 runbook 确认发布前已有可用的加密离机副本，并在 migration 前确认新批次离机复制与哈希校验成功；当前脚本不会替代这一步；
5. TOKEN、媒体签名和代理密钥另做仓库外加密备份，否则恢复数据后旧会话或历史媒体可能不可用。

### 4. 候选、migration 与切换

人工操作也必须遵守一键入口的顺序：候选镜像先离线构建并检查 → 停止 Web 写入 → 使用候选镜像和生产 `.env` 运行一次独立 migrator → 确认 schema → 启动候选 → 健康检查 → 最后写 `RELEASE`。

migration 失败立即停止，不连续重试，不让旧镜像盲目访问新 schema。任何删除/改写数据的 migration 都必须在隔离恢复库先演练并记录耗时与回滚方案。

由于当前固定目录、镜像标签和主机脚本可能与私有运维状态不同，实际 Docker 命令必须在部署前只读检查后生成；本文件不提供可能覆盖现有生产目录的猜测命令。

## 发布验证

### 美国本机

```bash
curl -fsS http://127.0.0.1:3000/live
curl -fsS http://127.0.0.1:3000/health
curl -fsS http://127.0.0.1:3000/ready
docker inspect couplechat-server --format 'status={{.State.Status}} restarts={{.RestartCount}} image={{.Image}}'
```

容器日志只在服务器本机查看；先脱敏 URL query、token、私聊和 AI 内容，禁止把原始日志直接粘贴到公开 Issue 或 AI 对话。

### 私有 origin

在美国或受信运维环境读取 root-only proxy key，请求 `https://chat.huhuhu.top/health`。带 key 必须成功；不带 key 返回 `403` 是预期。命令和输出不得打印 key。

### 公开入口

```bash
curl -fsS https://hoo66.top/live
curl -fsS https://hoo66.top/health
curl -fsS https://hoo66.top/ready
```

开发机再执行：

```powershell
cd server
npm run healthcheck -- https://hoo66.top
```

最后在真机验证登录、Socket 重连、文字收发、图片/视频/语音/表情上传、媒体 Range 播放、提醒、推荐、大橘和 AI 私聊。只有本机、origin、公开入口和真机都通过，才算服务端发布完成。

## 备份现状与恢复

备份供应商、容量、最近成功/失败和恢复日志只保存在私有 runbook。公开仓库只能证明当前脚本的设计和自动测试边界，不能证明它们已在生产运行。发布前必须检查实际文件、哈希、`consistency_mode`、恢复验证标记、离机副本和演练记录，不能只看 cron 或 `RESTORE-VERIFIED` 存在；任一项无法证明时停止发布。

代码层面，备份格式 v3 和恢复标记格式 v2 共用 v1–v31 版本感知的全表策略；恢复脚本会执行随机临时库真实 restore、schema/全表计数、两条关键序列和媒体抽样比对，并在成功删库后写标记。旧格式 v2 只允许降级验证且不会获得新标记。本次真实生产副本已完成一次完整验证；仍待完成的运维证据是目标 Linux 失败注入、加密离机复制确认，以及把这些步骤接入尚未实现的一键部署入口。

恢复顺序：

1. 停止所有写入；
2. 对故障现场再做一份只读保全；
3. 先重新执行 `verify-backup.sh`，在随机临时数据库恢复 dump，并用版本感知清单校验 schema、全部持久化表计数、`message_server_seq_seq`/`sync_event_seq` 状态和媒体抽样；不能只信任历史标记；
4. 解开同批次 uploads 到隔离目录，逐文件验证 manifest，而不是只依赖恢复脚本的抽样结果；
5. 按同一备份批次恢复数据库与 uploads；
6. 用与该 schema 兼容的镜像启动并完成三层健康检查；
7. 恢复后再开启定时任务和外部写入。

日本冷数据只在美国无法恢复时使用。切换日本前必须先停美国，不允许双写。

## 回滚边界

应用镜像回滚只有在旧镜像声明支持当前 schema 时才安全。当前服务启动要求精确 schema，而迁移只向前，不能默认“重新部署旧 SHA”就是回滚。

每个服务端发布 metadata 最终必须包含：

- source commit/tag；
- app version；
- `schema_min` / `schema_max`；
- migration 是否可逆、是否删除数据；
- 上一个已验证兼容镜像；
- 备份批次与恢复验证结果。

不兼容时只能恢复数据库+uploads+必要密钥的同一备份集，而不是单独切换旧镜像。
