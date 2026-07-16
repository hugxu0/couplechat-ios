# AGENTS.md

本文件适用于整个仓库。子目录若有更具体的 `AGENTS.md`，只能补充本文件，不能放宽安全和验证要求。

## 开工前

1. 执行 `git rev-parse --show-toplevel`、`git status --short --branch` 和 `git rev-parse HEAD`，确认仓库、分支、提交与用户已有改动。
2. 依次阅读 `Docs/README.md`、`Docs/current/PROJECT.md`、`Docs/current/KNOWN_ISSUES.md`，再按任务读取架构、契约或运维文档。
   涉及生产连接、两台 VPS 或交接时，还必须阅读 `Docs/operations/AI_HANDOFF.md`。
3. 先确认事实属于哪一层：源码、自动测试、GitHub Actions、IPA artifact，还是生产环境。不得由上一层推断下一层。
4. 保留用户已有改动。未经明确要求，不重置、不覆盖、不删除、不部署。

## 仓库事实

- 这是一个单仓库：`Sources/` 与 `CoupleChatTests/` 是客户端，`server/` 是服务端。
- iOS/iPadOS 最低版本为 26；设备范围是两台 iPhone 17 和一台 iPad，均使用最新稳定系统。
- 生产客户端只连接 `https://hoo66.top`。日本是入口，美国是唯一可写源站。
- CI IPA 未签名；Apple 免费账号的签名和侧载只能在用户自己的受信设备上完成。
- `Sources/Resources/cute_cat.glb` 已受版本控制并随 IPA 发布，不能当作缺失的本地私有资源。

## 阅读与搜索边界

默认忽略这些目录：`artifacts/`、`build-artifacts/`、`node_modules/`、`dist/`、`DerivedData/`、`server/uploads/`、`server/.data/`、备份和展开的旧发布包。它们不是源码或发布真相。

不要把仓库外的 VPS 凭据文档、IP 清单、订阅参数、数据库 dump、代理密钥或设备 UDID 复制进仓库、日志或回答。仓库只记录公开安全的拓扑和操作边界。

## 变更矩阵

| 改动 | 必须同时检查 |
|---|---|
| REST / Socket / Sync | 两端契约、调用方、协议测试、`Docs/architecture/API.md` 与 `DATA_SYNC.md` |
| 消息 / 已读 / outbox | SQLite、服务端事务、Socket 重连、Sync V2、幂等与多设备测试 |
| 数据库 | 只追加 migration；备份/恢复、当前与上一服务版本兼容性 |
| 上传 / 媒体 | 大小限制、流式 I/O、Range、签名 URL、清理、备份、两层 Nginx |
| iOS 构建 / 依赖 | `project.yml`、workflow、真机签名说明、版本与 artifact metadata |
| 服务端部署 | `server/` 发布包、固定 SHA、3000 端口、三层健康检查、失败回滚 |
| 生产拓扑 | `PRODUCTION_TOPOLOGY.md`；不得写入秘密值或真实凭据 |

设计目标不能写成已实现。当前行为、已验证结果、生产最后记录和计划必须使用明确标签。

## 安全规则

- 未经用户明确授权，不连接、修改或部署生产环境，不触发 migration，不写生产数据库。
- 即使获准部署，也要先确认目标主机、精确 commit/tag、备份结果和回滚边界；禁止发布 moving `main`。
- 不打印或提交 token、密码、数据库连接串、AI key、Bark key、代理 key、Apple 密码、2FA、证书私钥、provisioning profile 或 UDID。
- 不把免费签名凭据放入 GitHub Secrets；仓库流水线只生成 unsigned IPA。
- 日志与 AI Trace 不得持久化完整私聊、完整 prompt、工具结果或敏感 URL 查询参数。

## 验证

服务端改动至少运行：

```powershell
cd server
npm test
npm run build
```

iOS 改动至少通过对应的 GitHub Actions；涉及交互、音视频、签名或通知时还需在真机验证。文档改动至少运行链接/路径/命令静态检查和 `git diff --check`。

无法运行的验证必须明确写入结束报告，不能用“应该可以”代替。

## 完成报告

每次交付说明：

- Changed：改了什么；
- Validation：实际运行并通过什么；
- Not run：什么没跑以及原因；
- Contract impact：是否影响 REST/Socket/Sync/数据库；
- Production impact：是否需要迁移、部署、重签或刷新；
- Docs：更新了哪个权威文档。

不要创建日期审计报告、临时交接文档或重复 API 文档；Git 历史负责追溯。
