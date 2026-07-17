# 悄悄话当前项目

> 更新时间：2026-07-17。本文是产品现状的唯一入口，不记录开发过程与历史版本。

本文把源码、测试、构建产物和生产环境分开记录。详细缺陷与验收条件见 [KNOWN_ISSUES.md](KNOWN_ISSUES.md)。

## 状态证据

| 层级 | 最后核验 | 结论 |
|---|---|---|
| 本次审查基线 | `76d18046475668aeccc287746173a4be30bd3a0b` | 单仓库与生产拓扑保持不变；本轮加入固定 SHA 的快速服务端发布入口，schema 仍为 v31 |
| 服务端验证 | 2026-07-17 | 对 `76d18046475668aeccc287746173a4be30bd3a0b` 执行 `npm run check`：33 个测试、一次 PostgreSQL 18 当前行为烟测和生产编译全部通过；随后使用同一 SHA 的快速发布入口完成线上验收 |
| 最近一次 iOS 远程验证 | `4efff3c9d058d16a6ec48f8255e214d9f2a3225f` / quick run `29527650542` / IPA run `29527662722` | 新的单条快速验证链和 unsigned IPA 归档均通过；IPA artifact 已完成 metadata、SHA-256、资源和签名残留校验 |
| 生产环境 | 2026-07-17 | 美国唯一可写源站已部署 `76d18046475668aeccc287746173a4be30bd3a0b`，schema v31；本次使用快速路径，远端切换耗时 16 秒、含上传总耗时 24.2 秒，不运行 migration、不新建完整备份恢复。现行 quiesced 基线 `20260716T192532Z-589c7962924a` 继续有效；本机、私有 origin、公开入口、固定账号列表和 Socket.IO transport 均通过。日本入口保持原拓扑且不运行 CoupleChat Node/PostgreSQL；旧 release/incoming 和旧镜像标签已清理，仅保留 `rollback-4efff3c9d058d16a6ec48f8255e214d9f2a3225f` |

本机旧 IPA、tar、展开的 release 或备份目录不属于上述任何生产证据。

## 产品边界

悄悄话只服务 `xu` 与 `si` 两位固定用户，支持同账号在 iPhone/iPad 多设备同时登录。产品入口按当前 Tab 顺序为聊天、时光、大橘、计划和我的。

服务端不提供注册、邀请码、配对、创建情侣空间或加入其他情侣空间。现有情侣空间仍是共享数据的所有权边界，私人 AI、私人提醒和设备配置按账号隔离。

## 技术基线

- 客户端版本 `0.2.0 (11)`，Bundle ID `com.hugxu0.couplechat.native`，最低 iOS/iPadOS 26，Swift 5.9；工程由 XcodeGen 的 `project.yml` 生成。
- 客户端依赖精确版本 Socket.IO Client Swift `16.1.0` 和 GLTFKit2 `0.5.15`；3D 模型 `Sources/Resources/cute_cat.glb` 已受 Git 版本控制并随 IPA 发布，授权见同目录 `ThirdPartyNotices.txt`。
- 服务端使用 Node.js 22、Fastify 5、Socket.IO 4、PostgreSQL，生产公开基地址为 `https://hoo66.top`。
- 目标设备固定为两台 iPhone 17 和一台 iPad，均运行最新稳定 iOS/iPadOS 26；签名使用免费 Apple Personal Team，不支持 TestFlight/App Store。

## 已实现

### 账号与同步

- 固定双账号登录、设备会话查看与撤销。
- 多设备在线状态、严格已读、Socket 实时事件和前台补拉。
- SQLite 消息缓存、可靠发送队列、从云端最新页开始核对的完整历史同步、媒体缓存和 Sync cursor/ack。完整历史以本地条数达到服务端 `total` 为完成条件；离开存储页不会取消任务，显式暂停、登出或切换账号才会取消。
- 已登录用户启动时并行请求 bootstrap 与恢复账号专属 SQLite；网络不可用时仍可进入有界本地历史，回前台后再补快照、Sync V2 和 Socket 健康检查。

### 聊天

- 共同聊天与每个账号独立的大橘私聊。
- 文字、原图、视频、语音、文件、静态/动态贴纸、引用、搜索和完整撤回。
- 图片/视频预览、收藏、按账号独立保存的聊天主题与壁纸、Markdown 表格和 Mermaid 渲染。
- 语音异步转写、失败重试、历史补建和撤回级联。

### 时光、计划与大橘

- 纪念日、聊天统计、多本共同相册、朋友圈式分组动态、相册直接上传和那年今日。聊天统计优先采用服务端数据，网络失败时回退本地 SQLite；相册时间线按动态分组，缩略图统一裁切，轻点只浏览当前动态媒体，长按提供媒体操作，文案在正文右侧独立编辑。
- 今日推荐按北京时间 06:00 切换作息日：大橘给双方同一条内容/体验推荐，支持换一条、双方互荐、未读提示、收下与个人历史隐藏。
- 共享/私人日历、提醒、备忘、完成、删除和版本冲突处理。
- 共享提醒通知双方设备，私人提醒只通知创建者设备。
- 服务端持久化的大橘状态、互动冷却、日夜场景和 AI 私聊；客户端从随包 `cute_cat.glb` 加载 3D 模型，加载失败时显示占位。

### 设置与 AI

- 主题、深浅模式、头像、设备、Bark、收藏、按账号隔离且同账号多设备同步的表情库、存储和 Memory 控制中心。
- `@大橘`、图片理解、联网查询、来源卡片、事项确认卡和上下文摘要。
- 结构化 Memory、人物归属、纠正、忘记和定时维护；关系与理解可查看所引用的基础记忆。

## 当前限制

- Live Photo 尚未实现配对资源上传与原生预览，当前按静态图发送。
- iPad 双栏聊天、照片拖放和完整键盘快捷键尚未完成。
- Memory 本地离线缓存尚未完成。
- 日历事件本身尚不自动推送，当前只有提醒事项会按到期时间触发 Bark。
- 推荐变化通过 REST、Sync V2 和 App 内未读角标同步，当前不单独发送 Bark 推荐通知。
- 清空 App 数据后，已经丢失本地文件的失败媒体无法继续重传。
- iOS 自动验证依赖 GitHub Actions 或 Mac；真机仍需检查视觉、手势、蓝牙音频和双设备行为。
- GitHub 当前只生成 unsigned IPA；免费账号签名 7 天到期，三台设备需要定期刷新。完整流程见 [IOS_SIDELOAD.md](../operations/IOS_SIDELOAD.md)。
- 备份与恢复脚本仍共享 v1–v31 全表策略并校验关键序列；定时任务维护现行基线，普通代码发布不重复完整备份/恢复，只有 migration、数据修复、媒体结构变化或恢复切换才走 quiesced 备份路径。旧备份和旧发布物在确认现行基线后清理，边界见 [DEPLOYMENT.md](../operations/DEPLOYMENT.md)。
- Sync 提交顺序、SQLite 失败传播、频道隔离、Sync 协议版本、3D 加载状态和生产端口的代码修复已进入当前工作树；账号切换竞态、媒体 I/O、分页、生产安全和备份状态仍以 [KNOWN_ISSUES.md](KNOWN_ISSUES.md) 为准。

## 架构保护边界

### 客户端

- `ChatPersistence` 是生产 SQLite 的唯一入口；页面和 MainActor 不直接访问数据库。
- `ChatTimelineStore` 管理窗口与分页，`OutboxProcessor` 串行可靠发送，`clientId` 提供幂等。
- `ChatMessageCollection` 统一消息去重、排序和乐观消息替换。
- `PendingMessageFactory` 统一待发消息，`ReadReceiptCoordinator` 统一已读节流与单调时间戳。
- `MessageHistorySyncService` 负责完整历史落库；`MessageStore` 负责页面状态和业务协调。
- `ChatTimelineController` 负责 Collection View、diff、分页锚点和滚动决策。
- `ChatMediaViewerCoordinator` 统一聊天、相册和收藏的媒体预览转场。
- 相册媒体单元必须由完整按钮承载轻点与长按；固定比例裁切只作用于显示层，媒体转场锚点不得接收触摸，文案操作区不得覆盖媒体命中区域。
- 聊天布局、键盘/表情面板、滚动锚点和媒体转场不得在数据层清理中顺带改动。

### 服务端

- `server.ts` 只装配进程，`app.ts` 注册 HTTP，各领域路由与服务负责业务。
- 当前 schema 为 v31；v1–v31 迁移必须保留且不可改写，后续只能追加。
- 公聊事件发往 `couple:<id>`，私人事件发往 `account:<id>`。
- 数据访问集中在 `db/`，列表游标统一使用 `src/utils/cursor.ts`。
- TypeScript 启用未使用代码检查；撤回执行完整级联删除，宠物互动和提醒投递保持事务幂等。

## 验证基线

服务端改动至少执行：

```powershell
cd server
npm run check
```

iOS 快速验证 workflow 当前执行公开仓库安全、SwiftLint、结构护栏和 generic iOS 编译；XCTest 保留在 `CoupleChatTests`，需要时可按 [DEVELOPMENT.md](../development/DEVELOPMENT.md) 手动运行。unsigned IPA workflow 直接归档当前精确 commit，并继续校验 metadata、run/attempt、SHA-256、实际 `Info.plist` 和签名残留。仍需在三台真实设备验证视觉、手势、蓝牙音频和通知。

## 文档与完成定义

- 只维护 `Docs/README.md` 列出的现行文档，不新增历史目录、日期报告或阶段计划。
- 协议变化同时更新服务端、客户端、接口文档和测试。
- 行为、命令、部署或数据结构变化在同一提交更新对应文档。
- 不提交密钥、生产数据、媒体副本、数据库备份或构建产物。
