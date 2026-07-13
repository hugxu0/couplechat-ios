# AI 接手说明

> 更新时间：2026-07-13
>
> 当前分支：`main`
>
> 历史 PR：<https://github.com/hugxu0/couplechat-ios/pull/1>（已合并）

## 1. 当前结论

个人版 V1 已上线；2026-07-13 用户确认进入可扩展 V2：未来支持其他情侣注册配对、同账号 iPhone/iPad、多设备全量同步、共同相册/那年今日、共享日历、语音转写、Memory 控制中心和服务端持久化大橘。产品与迁移权威文档为 `V2_PRODUCT_PLAN.md`、`V2_ARCHITECTURE.md`，旧 R0-R8 文档保留为历史证据。

发布与后续维护状态：

- 完整 CI run `29175140556` 全部通过（R0-R8 发布基线）。
- V2 代码提交 `a4e1d74` 的完整 run `29211061229` 已通过 macOS/Xcode 26.3 验证；其中包含服务端、SwiftLint、结构护栏、iPhone 单测、聊天视觉 Fixture、iPad build、无签名 Archive 和 IPA 上传。
- 发布候选 IPA：`CoupleChat-unsigned-230`（用户真机回归通过）。
- 本地后续构建产物最新为 `CoupleChat-unsigned-247`（发布后的 Markdown / 确认卡等维护构建；不是新的正式发布标签）。
- V2 安装候选为 `CoupleChat-unsigned-252`；服务端已部署，iOS 仍待真机 V2 回归。
- 生产后端镜像：`couplechat-server:candidate-32ec642`（image `35ce3ca0…`），正式标签为 `couplechat-server:local`。
- 当前应用回滚镜像：`couplechat-server:rollback-20260713-064437-v10`；数据库回滚必须同时恢复下述 v10 备份。
- V2 发布备份：`/root/codex-backups/couplechat-v2-release/daily/20260712T223100Z-d9e287e294f5`，已完成临时库恢复和媒体抽样校验。
- 发布前备份：`/root/codex-backups/couplechat-release-20260712-094038`。
- 用户已完成单设备生产冒烟：普通消息、`@大橘`、AI 私聊、图片上传与预览全部通过。
- 当次发布按用户要求采用单设备豁免；R8.1 的双设备/iPad 真机矩阵仍保持未验收，这是残余风险，不是假装已测试。
- 发布后 `main` 已继续合入 Markdown 消息渲染、Mermaid 流程图、事项确认卡布局与归属等维护提交。
- 2026-07-13 完成仓库卫生整理：本地 `build-artifacts` 只保留 230/247 与生产 server 包；聊天 cell 辅助类型与记录页子视图完成纯文件拆分，不改业务行为。
- 2026-07-13 启动全量重设计阶段 0+1：硬化 `DS` token（字体/间距/状态色/Reduce Motion/UIKit 桥接），统一 `dsCard` 与语义组件，登录页与根 Tab 接入同一套样式。
- 2026-07-13 阶段 2 首页：`ChatHomeView` 拆入 `Sources/Features/Chat/Home/`（models / components / avatar / 装配），Profile 残留 `appSurface` 收敛为 `dsCard`。
- 2026-07-13 阶段 3 外围页：提醒页与我的页表面/字体/分段控件收敛到 `DS` 与 `dsCard`；不改业务请求与数据结构。
- 2026-07-13 阶段 4 外围页细化：记录/主题/存储/宠物/聊天首页常规字号与圆角收敛到 `DS.Typo`；装饰性大图标保留固定字号。
- 2026-07-13 结构整理：Chat 去 V2 命名并按 Session/Timeline/Media/Search/Settings 分层；Reminders/Profile 子文件与子目录收敛。
- 2026-07-13 Core 按 Models/Networking/Persistence/Chat/Shared/Media/Support 分层；互动 SwiftUI 展示移到 Chat/Presentation。
- 2026-07-13 R5.3/R5.4 继续收敛：消息映射与远端分页移出 `MessageStore`，Socket 生命周期和健康检查移入 `RealtimeConnectionCoordinator`，领域事件路由移入 `RealtimeEventRouter`；outbox 串行 replay、文件持久化/清理与 retry 判定移入 `OutboxProcessor`，上传/ack UI 投影仍由 `MessageStore` 协调。
- 2026-07-13 V2 第一批落地：系统自适应 Tab/侧栏、Universal iPhone+iPad 方向配置、窗口尺寸适配、Memory 正式 API 与设置控制中心。
- 2026-07-13 语义修正：撤回改为全量硬删除；已读只在聊天可见且 cell 已展示后上报，服务端游标单调递增。
- 2026-07-13 Bark 修正：共享提醒发双方、私人提醒只发 owner，删除广播保留 scope，投递结果持久化并在重启后补扫/去重/重试；iOS 不再重复安排本地到期通知。
- 2026-07-13 录音首次授权竞态与离页/后台中断已修正；媒体收藏按账号分区。
- 2026-07-13 V2 服务端与 v11–v22 已部署生产：注册/邀请码配对、多设备会话与设备级 Bark、conversation ownership、Sync V2、Memory、转写、相册、日历和持久化大橘均已上线；iOS 候选仍待真机验收。

详细改造与证据见 `Docs/RELEASE_REPORT_2026-07-12.md`。

## 2. 接手顺序

开始任何新任务前完整阅读：

1. `Docs/PROJECT_STATUS.md`
2. `Docs/V2_PRODUCT_PLAN.md`
3. `Docs/V2_ARCHITECTURE.md`
4. `Docs/ARCHITECTURE.md`
5. `Docs/DEVELOPMENT.md`
6. 与任务直接相关的 `Docs/API.md`、`Docs/AI.md` 或 `Docs/DEPLOYMENT.md`

然后运行：

```powershell
git status --short --branch
git log --oneline -8
```

工作树可能包含用户自己的改动；不得覆盖、回滚或顺手格式化无关文件。

## 3. 已建立的架构边界

客户端：

- `ChatPersistence` actor 是生产 SQLite 的唯一入口。
- `ChatTimelineStore` 持有可观察的消息窗口和分页状态。
- `OutboxProcessor` 串行处理可靠发送，`clientId` 是幂等与 pending 替换依据。
- `MediaUploadService` 负责媒体上传边界。
- `HistorySyncCoordinator` 拥有跨页面历史同步任务。
- `ChatTimelineController` 负责 collection view、diff、分页锚点与滚动决策。
- `ChatMediaViewerCoordinator` 统一聊天、图库和收藏的媒体 Viewer 转场（目录：`Features/Chat/Media/`）。
- 聊天功能目录已收敛为 `Home/`、`Session/`、`Timeline/`、`Media/`、`Search/`、`Settings/`、`Fixtures/`；会话入口为 `ChatView` → `ChatSessionScreen`。
- 记录页在 `Features/Records/`；提醒页在 `Features/Reminders/`（列表/卡片/编辑器/预览分文件）；我的页在 `Features/Profile/`，主题/存储/收藏分子目录。
- `Features/Records/`、`Reminders/`、`Pet/` 分别承载时光、计划和共同宠物；注册配对与设备管理位于 `Features/Auth/`、`Features/Profile/`。
- `SyncV2Repository` 负责持久化变更 cursor/ack；Memory、相册、日历、转写和宠物各自使用专用 Repository，不由页面直接拼请求。
- `MessageStore`/`ChatStore` 仍是兼容 facade；新增业务应进入对应 Repository、Store 或 Coordinator，不继续扩大 facade。

服务端：

- `server.ts` 只负责装配和生命周期启动。
- `app.ts` 注册 HTTP 路由，Socket 入口位于 `socket/`。
- PostgreSQL 访问拆到 `db/client.ts`、`transaction.ts`、`rows.ts`、`migrate.ts`。
- 生产已执行 migration v1–v22，内容全部冻结并受哈希/升级测试保护；后续只能追加新版本。
- 撤回事务硬删除服务端派生数据；领域事件只做历史 Memory 孤儿清理。
- Reminder Bark delivery 已持久化并按设备 endpoint 独立 claim/重试；shared 发双方、personal 只发创建者。通用 notification intent 仍是后续架构目标，不是当前提醒功能的阻塞项。
- 公聊房间按 `couple:<id>`、个人事件按 `account:<id>` 隔离；legacy `user:<username>` 只保留兼容监听。
- scheduler、上传清理、Socket.IO、数据库按确定性顺序关闭。
- `/live` 只表示进程存活，`/ready` 验证数据库，旧 `/health` 保持兼容。

## 4. 不可破坏的产品行为

- 不改已经通过验收的键盘、输入栏 inset 和分页锚点链路，除非有稳定复现的新 Bug。
- 不删除或降级 AI 私聊、公聊 `@大橘`、Memory、确认卡、记录、提醒、纪念日和互动特效。
- 失败气泡只删除本地 outbox；已发送消息的服务端撤回必须执行完整级联删除，不能恢复占位或“重新编辑”。
- 已读不能根据启动时间、收到 Socket 或仅进入页面推断；必须由当前可见且已展示的消息 cell 驱动。
- 不绕过 `clientId` 幂等，不让一次重试产生两条正式消息。
- 不让页面生命周期重新拥有历史同步或 outbox 长任务。
- 不在 MainActor 或 View 中直接访问 SQLite。
- 不修改已经生产执行的 PostgreSQL migration（当前 v1–v10），只能追加；尚未发布的 v11–v22 可在首次生产执行前修正，但一经执行同样冻结。
- 不记录 token、密码、API key、数据库连接串或完整私聊正文。

## 5. 验证基线

后端改动至少执行：

```powershell
cd server
npm test
npm run build
```

iOS 改动必须通过 GitHub Actions。完整验证包括：

- SwiftLint 与新增 Swift 文件结构护栏；
- iPhone 单元测试；
- DEBUG-only 聊天顶部 UI Fixture；
- iPad Simulator build；
- unsigned Archive 和 IPA 打包；
- 服务端 test/build。

视觉或手势问题仍由用户在真机验证，不要求截图。大任务按阶段完成后统一构建一次，不要每个小改动都生成 IPA。

## 6. 生产操作

生产目录是 `/opt/couplechat-ios/server`，公网地址是 `https://hoo66.top`。任何部署前必须备份 PostgreSQL、uploads 和配置，并保留上一版镜像。上线后至少检查：

```bash
curl -fsS http://127.0.0.1:8080/live
curl -fsS http://127.0.0.1:8080/ready
curl -fsS https://hoo66.top/health
curl -fsS https://hoo66.top/ready
docker compose -f compose.production.yml ps
docker compose -f compose.production.yml logs --tail=100 couplechat-server
```

不得删除当前发布备份、回滚镜像或仍需保留的旧 IPA。恢复数据库属于高风险操作，必须先验证 dump 并再次备份当前状态。

## 7. 当前已知限制

- 新注册情侣当前使用只看本条消息的无历史 AI 模式；完整 Agent/MCP 历史检索与自动 Memory 提取仍只对 legacy `xu/si` 开放。
- Sync V2 已做前台轮询补拉，但 `sync:available` Socket 唤醒、通用 mutation 幂等和 cursor retention/410 全量重建策略尚未完整接入客户端。
- Bark 点击后的页面 deep link 尚未接入。
- iPad 真机和两台设备同时在线的完整矩阵尚未执行；聊天主从双栏、照片拖放和完整键盘快捷键仍待补齐。
- 相册已支持从聊天入册及相册内直接选择普通照片/视频；Live Photo 仍只会在聊天选择阶段降级成静态图，尚未实现配对资源发送与 `PHLivePhotoView` 预览。
- Windows 不能本地编译 iOS，需依赖 GitHub Actions 或 Mac；真机反馈第二轮已通过完整 macOS CI 与 Release Archive（`29215988819`）。
- 清空 App 数据后，已丢失本地文件的失败媒体无法继续重传。
- `MessageStore` 与 `ChatStore` 仍是兼容 facade；新增领域能力不得重新塞回 facade。

## 8. 当前允许的下一步

优先完成这些仍有明确边界的工作：

1. 在 macOS CI 跑 SwiftLint、iPhone 单测、iPad build、Archive 和 IPA 打包，修完所有 Swift 编译或结构门槛问题。
2. 把 Agent/MCP/Memory runtime 从 legacy 字符串上下文迁移到 `conversation_id/account_id/couple_id`，再向其他情侣开放完整 AI。
3. 补 `sync:available` 唤醒、preference 云同步和 cursor 过期重建；保持 REST cursor 为事实补漏链路。
4. 有第二台设备时执行多设备/iPad 真机矩阵，并补聊天 iPad 双栏、拖放和键盘交互。
5. 在隔离环境做 v10 → v22 migration、备份、真实恢复和回滚演练；确认后再安排生产发布。

R5.3/R5.4 的历史拆分背景见 `Docs/REFACTOR_PLAN.md`；V2 的现行边界以 `V2_ARCHITECTURE.md` 为准。
