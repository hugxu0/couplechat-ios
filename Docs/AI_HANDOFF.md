# AI 接手说明

> 更新时间：2026-07-13
>
> 当前分支：`main`
>
> 历史 PR：<https://github.com/hugxu0/couplechat-ios/pull/1>（已合并）

## 1. 当前结论

主体功能已经上线，R2/R3 的用户交互方案不应无复现地推倒重做。结构治理仍有明确余项：R5.3/R5.4 尚未完全达到计划边界；R8.1 的双设备/iPad 真机矩阵也尚未执行。后续应把它们当作有边界的维护工作，而不是重新发起一次全量重构。

发布与后续维护状态：

- 完整 CI run `29175140556` 全部通过（R0-R8 发布基线）。
- 发布候选 IPA：`CoupleChat-unsigned-230`（用户真机回归通过）。
- 本地后续构建产物最新为 `CoupleChat-unsigned-247`（发布后的 Markdown / 确认卡等维护构建；不是新的正式发布标签）。
- 生产后端镜像：`couplechat-server:candidate-6a2e833`，正式标签为 `couplechat-server:local`。
- 回滚镜像：`couplechat-server:rollback-20260712-094038`。
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
- 2026-07-13 R5.3/R5.4 继续收敛：消息映射与远端分页移出 `MessageStore`，Socket 生命周期和健康检查移入 `RealtimeConnectionCoordinator`；outbox 串行 replay、文件持久化/清理与 retry 判定移入 `OutboxProcessor`，上传/ack UI 投影仍由 `MessageStore` 协调。

详细改造与证据见 `Docs/RELEASE_REPORT_2026-07-12.md`。

## 2. 接手顺序

开始任何新任务前完整阅读：

1. `Docs/PROJECT_STATUS.md`
2. `Docs/ARCHITECTURE.md`
3. `Docs/DEVELOPMENT.md`
4. 与任务直接相关的 `Docs/API.md`、`Docs/AI.md` 或 `Docs/DEPLOYMENT.md`

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
- `MessageStore`/`ChatStore` 仍是兼容 facade；新增业务应进入对应 Repository、Store 或 Coordinator，不继续扩大 facade。

服务端：

- `server.ts` 只负责装配和生命周期启动。
- `app.ts` 注册 HTTP 路由，Socket 入口位于 `socket/`。
- PostgreSQL 访问拆到 `db/client.ts`、`transaction.ts`、`rows.ts`、`migrate.ts`。
- 已发布 migration v1-v10 受哈希测试保护，只能追加新版本。
- AI Memory 撤回失效通过领域事件解耦。
- scheduler、上传清理、Socket.IO、数据库按确定性顺序关闭。
- `/live` 只表示进程存活，`/ready` 验证数据库，旧 `/health` 保持兼容。

## 4. 不可破坏的产品行为

- 不改已经通过验收的键盘、输入栏 inset 和分页锚点链路，除非有稳定复现的新 Bug。
- 不删除或降级 AI 私聊、公聊 `@大橘`、Memory、确认卡、记录、提醒、纪念日和互动特效。
- 不把失败气泡的本地删除与已发送消息的服务端撤回合并。
- 不绕过 `clientId` 幂等，不让一次重试产生两条正式消息。
- 不让页面生命周期重新拥有历史同步或 outbox 长任务。
- 不在 MainActor 或 View 中直接访问 SQLite。
- 不修改已执行的 PostgreSQL migration，只能追加。
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

- 大橘宠物页仍是展示占位，不具备完整数值和持久化系统。
- Bark 点击后的页面 deep link 尚未接入。
- iPad 真机和两台设备同时在线的完整矩阵尚未执行。
- Windows 不能本地编译 iOS，需依赖 GitHub Actions 或 Mac。
- 清空 App 数据后，已丢失本地文件的失败媒体无法继续重传。
- `MessageStore`（约 1200 行）与 `ChatStore`（约 770 行）仍是兼容 facade；分页/搜索/已读/发送编排和 Socket 生命周期尚未完全下沉。
- `ChatNativeMessageCell` 本体仍较大，后续可继续按内容类型拆 extension，但不得与发送可靠性改动混提。

## 8. 当前允许的下一步

只允许这些有边界的维护，不要重开全量重构：

1. 继续 R5.3：把分页、搜索、已读和消息合并抽到 Repository；把 outbox flush 真正下沉，而不是只留串行锁。
2. 继续 R5.4：抽出 `RealtimeConnectionCoordinator`，削减 `ChatStore` 对全 App 的桥接 API。
3. 有第二台设备时执行 R8.1 双设备/iPad 真机矩阵。
4. 纯文件级拆分（如 `ChatHomeView`、`RemindersView`）可在不改行为的前提下继续做。

R5.3/R5.4 和 R8.1 的剩余工作细节见 `Docs/REFACTOR_PLAN.md`。其他新问题应先确认复现细节，再做有边界的修复。
