# 悄悄话 R0-R8 完成报告

> 完成日期：2026-07-12
>
> 工作分支：`agent/project-handoff-cleanup`
>
> 发布候选：`CoupleChat-unsigned-230`
>
> 已部署服务端代码点：`6a2e833`

## 1. 结果摘要

本轮没有推倒重写产品，而是在保持现有聊天、AI、记录、提醒和纪念日功能的前提下，依次修复消息可靠性与聊天交互问题，再拆分高风险职责，最后整理服务端和交付链路。

最终结果：

- R0-R8 全部验收，客户端候选已安装，生产后端已切换。
- 用户分阶段确认了同步、失败消息、聊天顶部、媒体 Viewer、分页、表情面板、媒体气泡和首页/功能页视觉修改。
- 生产冒烟中的普通消息、`@大橘`、AI 私聊、图片上传和图片预览全部通过。
- 完整 CI run `29175140556` 全绿。
- 生产数据、uploads、配置、旧服务镜像和旧 IPA 均保留，可执行明确回滚。
- 用户只有一台设备，因此双设备与 iPad 真机矩阵采用明确豁免，不伪装成已测试。

## 2. 改造前的主要问题

开始时的风险集中在五处：

1. 历史同步任务属于页面生命周期，离开存储页会被取消。
2. 失败媒体消息缺少完整的重试/删除闭环，断网图片可能一直“发送中”，错误预览还会落到头像。
3. 聊天顶部叠加多层自定义模糊、亮度判断和阴影，视觉生硬且容易互相影响。
4. 媒体预览、时间线 diff、分页锚点和“回到底部”按钮逻辑混在巨型控制器里，修一个交互容易破坏另一个。
5. 客户端 Store、SQLite 和服务端数据库/生命周期边界偏大，测试和生产诊断不足。

本轮以“先加护栏、再修 Bug、最后拆边界”为顺序，避免在没有可验证基线时做大规模搬迁。

## 3. R0：验证与交付护栏

### 行为基线

- 为时间线 reload、底部保持、阅读锚点和 pending 消息稳定 ID 建立纯逻辑测试。
- 把键盘、输入栏 inset、媒体转场、失败消息和同步生命周期列为保护行为，避免无关重构改变手感。

### GitHub Actions

- 服务端 test/build 与 iOS 验证拆成可诊断步骤。
- 固定 Xcode 26.3，最低系统为 iOS 26。
- 自动选择当前 runner 中最新兼容的 iPhone 17/iPad runtime。
- 增加 SwiftLint、新 Swift 文件结构护栏、iPhone 单测、iPad build、Archive、IPA 和 `.xcresult` artifact。
- 增加 DEBUG-only 聊天顶部 UI Fixture，视觉验证不登录生产账号、不依赖网络。

这部分解决的是“改完以后不知道哪里坏、失败后没有证据”的问题。

## 4. R1：同步与可靠发送

### 历史同步

- 新增 `HistorySyncCoordinator`，由 App/Store 长期持有同步任务。
- 离开存储页面不再取消；显式暂停、登出或账号切换才停止。
- 页面重新进入后读取同一个任务状态，不从零创建第二套进度。
- App 被系统挂起后依靠本地游标继续，不承诺不符合 iOS 规则的无限后台执行。

### 失败消息闭环

- 所有 optimistic 消息以 `clientId` 为首选定位依据。
- 失败文字、图片、视频、语音、文件和 Live Photo 均支持重试或删除。
- 重试前检查本地媒体，缺文件时保持失败状态并给出可操作提示。
- 删除顺序覆盖 outbox、内存气泡和本地临时文件；Live Photo 同时处理照片与配对视频。
- 服务端继续以 `clientId` 保证幂等，避免一次重试生成两条正式消息。
- 修复断网媒体一直“发送中”、失败媒体预览落到头像、失败视频黑屏但显示成功等问题。

## 5. R2：聊天顶部

- 建立亮色、暗色、高对比壁纸及连接/AI 状态的可重复 Fixture。
- 验证并采用系统原生导航栏方案。
- 移除顶部专用多层 blur、亮度阈值、手工文字阴影和重复材质。
- 返回按钮、标题/在线状态和右侧菜单进入同一个系统导航容器。
- 按真机反馈继续调整左右按钮对称、标题胶囊宽度和渐变模糊过渡。

结果是顶部材质由系统统一采样，减少自定义透明层互相叠加造成的白雾、硬边和明暗闪烁。

## 6. R3：共享媒体 Viewer

- 新增 `ChatMediaViewerCoordinator`、转场 animator、交互 controller 和 host controller。
- 聊天媒体不再依赖旧 `fullScreenCover` 路径。
- 图片从消息气泡 frame 放大到 aspect-fit，退出尽可能回到原消息；源 cell 离屏时使用安全 fallback。
- 下拉手势连续驱动位移、缩放和背景透明度，支持完成、取消、速度阈值和方向判定。
- 视频开始退出时暂停，取消退出后恢复原状态。
- 聊天、媒体图库和收藏页复用同一 Viewer 内容与转场入口。
- 根据真机反馈统一新旧图片气泡尺寸、头像/回执间距和小圆角。

这部分同时修复了“下拉退出后图片消失但聊天页冻结”的致命交互问题。

## 7. R4：聊天时间线

- `ChatTimelineBuilder` 负责时间分隔、连续发送者分组、系统消息和 AI activity 的纯构建逻辑。
- `ChatScrollReducer` 用状态与事件决定初次定位、保持底部、保持阅读锚点、显示回到底部按钮和搜索跳转。
- `ChatMessageActionProvider` 统一 copy/reply/recall/re-edit/retry/discard 动作矩阵。
- `ChatTimelineController` 拥有 collection view、cell、diff、分页和滚动锚点。
- `ChatViewController.swift` 主文件缩到约 334 行，其余按附件、composer、媒体选择、录音和时间线职责拆分。

真机回归修复包括：

- 进入聊天时最后一条消息先藏到输入栏下再上弹。
- 发送文字、图片、表情或语音时“回到底部”按钮瞬间闪现。
- 向上加载更旧消息或搜索定位后向下加载时整页跳动。
- 顶部松手刷新期间偶发崩溃。
- 刷新后落到分页最早一条而不是与现有窗口相连的最后一条。
- 表情面板高度、底部空隙、分类位置和分组首图溢出。

## 8. R5：客户端数据边界

- 引入 `ChatRepositoryProtocol`、`ChatPersistenceProtocol` 和 `OutboxProcessing`。
- `ChatPersistence` actor 成为生产 SQLite 的唯一入口。
- `ChatLocalDatabase` 只在 actor 内管理 connection 与 SQL，页面和 MainActor 不再直接同步访问。
- `ChatTimelineStore` 管理可观察的窗口、已读和分页状态。
- `OutboxProcessor` 串行处理发送队列。
- `MediaUploadService` 独立处理 multipart、流式上传和响应解码。
- `DailyContentRepository`、`PersonalItemsRepository`、`LocalDataRepository` 分别承接每日内容、提醒/备忘和统计/存储。

`MessageStore` 与 `ChatStore` 为现有页面保留兼容 facade。它们仍然偏大，但底层所有权已经拆出；后续应继续让新业务落到专用对象，而不是再次扩张 facade。

## 9. R6：页面设计系统

- 建立 `AppPageBackground`、`RootPageHeader`、`StatusBanner`、`AppEmptyState`、`DestructiveActionRow` 和 `PairedEchoIndicator`。
- 统一首页、记录、提醒、我的、存储、主题和登录页的背景、标题基线、卡片表面和状态反馈。
- 全局卡片使用统一大圆角 token，清理提醒/记录页遗留的小圆角。
- 首页改为“漫长悄悄话”目标布局，调整最新消息容器、高度、边框、刷新回弹和明暗模式渐变。
- 页面底色统一到动态渐变，深色模式使用独立夜间配色。
- 当时保留宠物页现状，不把展示占位扩展进 R6；后续未发布 V2 已按独立产品任务完成持久化重做，见第 15 节。

## 10. R7：服务端模块化与可观测性

### 测试

- 保留最终 PostgreSQL smoke，并增加 auth、message、upload、sync、personal-items、AI memory、AI queue、migration、领域事件、shutdown 和 operation log 等领域测试。
- 当前共有 17 个后端领域测试，测试不连接生产数据库、不发送真实 Bark 或 AI 请求。

### 数据库

- 拆分 `db/client.ts`、`transaction.ts`、`rows.ts`、`migrate.ts` 和稳定 re-export `index.ts`。
- v1-v10 已发布 migration 内容不变，并由哈希测试保护。
- 6 万条消息夹具下，bootstrap、before、around 查询均使用现有 channel/timestamp 索引。
- 文本搜索在 5 万条 couple 消息上约 4.8 ms，低于 100 ms 证据阈值，因此没有为了“看起来更快”追加索引或 migration。

### 解耦与生命周期

- 消息撤回发布领域事件，AI Memory 订阅后使相关证据失效。
- reminder/personal items 使用依赖注入，减少全局可变实例。
- shutdown 依次停止 scheduler、上传清理、Socket.IO 和数据库。
- Socket 路由只负责解析、use case、emit/ack，不继续堆业务分支。

### 生产诊断

- send/upload/sync/AI reply 增加结构化 operation log，保留 requestId、clientId、channel、耗时和结果。
- 日志明确排除 token、密钥、连接串和消息正文。
- 固定错误码供客户端展示可操作提示。
- `/live` 表示进程存活，`/ready` 验证数据库，`/health` 保持旧客户端和运维兼容。

## 11. R8：发布、备份与回滚

### 自动验证

完整 GitHub Actions run `29175140556` 通过：

- 服务端 `npm test` 与 `npm run build`；
- SwiftLint 和结构护栏；
- 90 个 iOS 单元测试；
- 聊天顶部 UI Fixture；
- iPad Simulator build；
- unsigned Archive 与 IPA 打包。

候选 IPA 位于：

```text
build-artifacts/CoupleChat-unsigned-230/CoupleChat-unsigned.ipa
```

### 生产备份

发布前备份：

```text
/root/codex-backups/couplechat-release-20260712-094038
```

包含：

- `couplechat.dump`，PostgreSQL custom format，`pg_restore -l` 可读；
- `uploads.tar.gz`；
- `config.tar.gz`；
- `SHA256SUMS`，全部校验通过。

### 部署

- 旧正式镜像保留为 `couplechat-server:rollback-20260712-094038`。
- 新候选为 `couplechat-server:candidate-6a2e833`。
- 候选先在 `127.0.0.1:18080` 做 canary，`/live`、`/ready`、数据库和账号检查通过。
- 正式容器切换后重启次数为 0。
- 本机与公网 `/health`、`/live`、`/ready` 全部返回正常。
- `/api/accounts` 仍只包含 `xu` 和 `si`。
- AI/Memory 与 reminder 正常初始化，无重启循环。

VPS 只有约 458 MB 可用内存，完整 Docker `npm ci` 构建失败。本次使用旧运行时镜像并只覆盖本地已完成 test/build 的 `dist`，随后通过独立 canary 验证再切换正式标签。这个限制已写入部署文档。

## 12. 最终文件清理

收尾阶段重新按全仓符号引用审计，而不是凭文件名删除。已清理：

- 完全无调用的 `Sources/DesignSystem/UIKitBridge.swift`。
- 完全无调用的 `Sources/Features/Chat/Session/ChatSharedViews.swift`。
- 未使用的 `AppSectionHeader`、`AppCard`、`DynamicGradientBackground`、`ChatGlassButton`。
- 服务端无调用的旧 helper/type：`resolveUsername`、`parseActions`、`latestTs`、`tracePrompt`、`visionEnabled`、`createSystemMessage`、`ReadReceiptPayload`、`deleteSharedItem`。

删除后重新执行服务端 typecheck、17 个领域测试、完整 PostgreSQL smoke 和生产 build，全部通过。构建产物、发布备份、回滚镜像和旧 IPA 没有删除，因为它们承担诊断或回滚职责，不属于无用源码。

收尾提交为 `23ae071`。最终验证记录如下：

- 完整 run `29176219584` 的服务端 test/build、SwiftLint、结构护栏和 iPhone 单测均通过。
- 同一 run 的 UI Fixture 已完成编译，但 GitHub runner 在通过 Xcode 启动 App 时超过 60 秒，报 `Timed out while launching application via Xcode`；这不是测试断言或源码编译失败。
- 按用户要求取消完整重跑，改用快速 Archive run `29176467187`。
- 快速 run 的工程生成、unsigned Archive、IPA 打包和 artifact 上传全部通过；artifact 为 `CoupleChat-unsigned-232`，大小 2,668,514 bytes。
- 本次收尾不改变产品行为，因此没有要求用户重新安装；已上线并完成人工冒烟的候选仍是 `CoupleChat-unsigned-230` 与服务端 `6a2e833`。

## 13. 当前架构总览

```text
iOS App
  AppState / AuthStore / SharedStore
  ChatStore compatibility facade
    ChatTimelineStore
    HistorySyncCoordinator
    Repository boundaries
    ChatPersistence actor -> SQLite cache
    OutboxProcessor -> MediaUploadService -> REST/Socket
  ChatViewController
    ChatTimelineController
    ChatComposerView
    ChatMediaViewerCoordinator
        |
        | HTTPS + Socket.IO
        v
nginx -> Fastify / Socket.IO
  auth, chat, sync, upload, personal items, shared, daily
  AI Agent / MCP / Memory / reply queue
  domain events / deterministic shutdown / operation logs
        |
        +-> PostgreSQL (business source of truth)
        +-> uploads/ (media)
        +-> Bark (offline push)
```

## 14. 残余限制与后续建议

- iPad 真机和双设备同时在线矩阵未执行；以后有第二台设备时补测即可。
- 截至原始发布点宠物页仍是展示占位；后续未发布 V2 已完成独立状态、玩法和持久化设计，见第 15 节。
- Bark deep link 尚未实现。
- `MessageStore`/`ChatStore` 兼容 facade 仍偏大，但不应为了追求行数立刻再次拆分；等新需求出现时沿现有 Repository/Coordinator 边界迁移。
- Windows 不能本地编译 iOS，iOS 改动继续依赖 GitHub Actions 或 Mac。
- 用户清空 App 数据后，本地文件已经消失的失败媒体无法原地重传，只能删除后重新选择。

后续维护的原则是：先稳定复现、再做局部修改；一个大任务完成后统一跑完整验证和真机回归，不在每个小改动后反复构建 IPA。

## 15. 2026-07-13 V2 候选补充（尚未发布）

本节记录 7 月 12 日正式版本之后的工作树，不覆盖上文历史发布结论，也不表示已经部署生产。

### 已完成代码

- 注册、其他账号登录、创建两人空间、邀请码配对，以及设置内邀请码/已登录设备管理。
- account/couple/member/device/session/conversation 所有权切流；两对测试情侣的消息、设置、提醒、相册、日历、宠物和删除事件互相隔离。
- iPhone/iPad 同账号多设备会话与设备级 Bark；presence 改为按连接判断，一台设备后台不会覆盖另一台前台在线状态。
- 严格已读只由 active 可见聊天页内已经展示的 cell 上报；撤回限制为 2 分钟并硬删除消息、引用、收藏、上传派生、转写、Memory 证据和离线 tombstone。
- Sync V2 cursor/ack 与前台补拉；Memory 控制中心完成分页、版本冲突、跨设备刷新和删除 exclusion。
- 共同相册/那年今日、共享/私人日历、服务端语音转写 worker、历史语音补建，以及服务端持久化的大橘共同养成。
- 大橘玩法采用无惩罚设计：两人异步回答“今天一起”，完成后只结算一次内容藏品和足迹；摸摸、碰爪、逗猫棒不限制次数。
- 根导航改为五入口“聊天 / 时光 / 大橘 / 计划 / 我的”，启用 Universal iPhone+iPad、自适应侧栏、横竖屏和宠物宽屏布局。
- 轻量备份升级为原子归档、全量 SHA、媒体 manifest、受控停写 hook 和真实临时数据库恢复校验；可在 v10 旧结构与 v22 新结构上按实际存在表核对。

### 数据库候选

- v1–v10 是已发布冻结边界，哈希测试保持不变。
- v11–v22 是同一批尚未生产发布的 additive 候选：硬删除旧撤回、Bark ledger、身份/设备、conversation ownership、Sync V2、tenant Memory、转写、相册、日历和宠物。
- 生产 Web 默认 `RUN_MIGRATIONS=false`；发布必须先做并恢复验证备份，再单独运行 `npm run migrate`，不能依赖 Web 进程启动自动迁移。

### 当前验证

- Windows 本地已通过应用代码与运维脚本两套 TypeScript typecheck。
- 服务端 29/29 单元与 PostgreSQL 集成测试已通过；覆盖认证/设备/配对、严格已读、硬撤回、Bark、Sync、Memory、转写、相册、日历、宠物、迁移升级、presence 和 AI 确认卡并发收敛。
- 独立 PostgreSQL smoke 已通过，服务端 production build 已通过。由于工具单次执行时限，最终验证采用与 `npm test` 等价的 typecheck、`test:unit`、`smoke:postgres` 分步执行。
- 备份脚本 `bash -n` 通过；真实生产凭据和真实生产恢复演练尚未执行。
- Windows 没有 Xcode/Swift 工具链；V2 代码提交 `a4e1d74` 已由 GitHub Actions run `29211061229` 在 macOS/Xcode 26.3 完整通过 SwiftLint、结构护栏、iPhone 单测、聊天视觉 Fixture、iPad Simulator build、无签名 Archive 与 IPA 打包。
- CI 产物为 `CoupleChat-unsigned-252`。它是未签名、未部署、未做 v10→v22 生产迁移和真机 V2 回归的安装候选，不是新的正式发布版本。

### 仍然明确保留的边界

- legacy `xu/si` 继续使用完整 Agent/MCP/Memory；新注册情侣先使用只读当前消息的无历史 AI 模式，避免旧全局工具串用上下文。
- 相册 MVP 从聊天媒体入册，尚未支持在相册页直接拍摄/选图。
- 日历本身不自动推送；需要 Bark 到期通知时使用“提醒”，shared 发双方、personal 只发创建者。
- Bark deep link、Memory 来源跳转、完整 iPad 聊天主从栏、拖放和真机多设备矩阵仍未验收。
