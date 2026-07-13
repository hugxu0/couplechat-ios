# 悄悄话当前项目文档

> 更新时间：2026-07-14
>
> 这份文档是当前状态、接手说明、保护边界和下一步的唯一入口。历史版本与发布报告统一存放在 `../archive/`，不能用来覆盖本文的现行结论。

## 1. 产品边界

悄悄话是只服务 `xu` / `si` 两位固定用户、支持多设备同步的情侣聊天 App。客户端支持 iPhone/iPad，服务端使用 Fastify、Socket.IO、PostgreSQL 和媒体文件存储。

当前产品入口为：聊天、时光、计划、大橘、我的。外部 API、数据库表和 Socket 事件名称保持兼容，内部代码按 `Moments / Plans / Daju / Account` 统一命名。

产品不开放注册、邀请码或新增情侣空间。账号由服务端配置维护，现有情侣空间继续作为共享数据的所有权边界。

## 2. 当前已实现

### 账号与同步

- 两位固定账号登录和设备会话管理；公开注册及邀请码配对已移除。
- iPhone/iPad 同账号登录、在线状态、严格已读和离线补漏。
- SQLite 消息缓存、可靠发送队列、Sync V2 cursor/ack 和前台补拉。

### 聊天

- `couple` 公聊与每个账号独立的 `ai` 私聊。
- 文字、图片、视频、语音、文件、贴纸、引用、搜索和两分钟撤回。
- 媒体缓存、收藏、壁纸、预览转场、Markdown 表格和 Mermaid 渲染。
- 语音异步转写链路已支持失败重试、历史补建和撤回级联；Live Photo 仍按静态图处理。

### 时光与计划

- 纪念日、聊天统计、共同相册、那年今日和相册内直接选择照片/视频发表动态。
- 共享/私人日历、提醒、备忘、完成/删除和版本冲突处理。
- Bark 通知规则：共享提醒通知双方，私人提醒只通知创建者。

### 大橘与我的

- 服务端权威的大橘状态、互动、共同回应、布置和足迹数据。
- 大橘 3D 模型、日夜背景、互动冷却和 AI 私聊入口。
- Memory 控制中心、主题、深浅模式、头像、设备、Bark key、收藏和存储管理。

### AI

- 公聊 `@大橘`、AI 私聊、图片理解、联网搜索、来源卡片和事项确认卡。
- 结构化 Memory、原文证据、上下文摘要和定时维护。
- Agent/MCP/Memory 使用现有固定情侣空间和两个私人 AI 会话。

## 3. 当前限制

- Sync V2 的 `sync:available` Socket 唤醒、通用 mutation 去重和 cursor 过期重建尚未全部接入客户端。
- Memory 来源暂不能一键跳回聊天，本地 Memory 离线缓存尚未完成。
- Bark 点击后的页面 deep link 尚未接入。
- iPad 双栏聊天、照片拖放、完整键盘快捷键，以及两台设备同时在线的真机矩阵仍待补齐。
- Live Photo 尚未实现配对资源上传与原生预览。
- 清空 App 数据后，已经丢失本地文件的失败媒体无法继续重传。
- Windows 无法本地编译 iOS，iOS 验证依赖 GitHub Actions 或 Mac。

## 4. 不可破坏的架构边界

### 客户端

- `ChatPersistence` 是生产 SQLite 的唯一入口，页面和 MainActor 不直接访问数据库。
- `ChatTimelineStore` 管理消息窗口和分页；`OutboxProcessor` 串行处理可靠发送，`clientId` 负责幂等。
- `ChatMessageCollection` 是内存消息去重、排序以及乐观消息替换的唯一入口；禁止在 Socket、分页或 ACK 分支各写一套数组合并逻辑。
- `PendingMessageFactory` 统一创建乐观消息和 outbox 项，`ReadReceiptCoordinator` 统一已读节流与单调时间戳。
- `MessageHistorySyncService` 负责完整历史分页落库；`MessageStore` 只负责页面可观察状态和业务协调。
- `MediaUploadService` 负责媒体上传，`HistorySyncCoordinator` 负责跨页面历史同步。
- `ChatTimelineController` 负责 Collection View、diff、分页锚点和滚动决策。
- `ChatMediaViewerCoordinator` 统一聊天、图库和收藏的媒体 Viewer 转场。
- `ChatStore` / `MessageStore` 仍是兼容 facade；新增能力必须落到 Repository、Store 或 Coordinator。
- 聊天布局、键盘联动、滚动锚点和媒体转场集中在 `Features/Chat/Session`、`Timeline` 与 `Media`，数据层重构不得顺带改变这些视觉行为。

### 服务端

- `server.ts` 只负责进程装配和生命周期；`app.ts` 负责 HTTP 路由注册。
- PostgreSQL 访问集中在 `db/`；当前 schema 为 v24，v1–v23 保持不可改写，后续迁移只能追加。
- Socket 入口位于 `socket/`，业务写入必须经过领域服务和同步事件。
- 分页游标统一使用 `src/utils/cursor.ts`，新增列表接口不得复制 Base64 编解码实现。
- TypeScript 已启用 `noUnusedLocals` 与 `noUnusedParameters`，未使用代码必须在编译阶段失败。
- 公聊按 `couple:<id>`、AI 事件按 `account:<id>` 隔离；legacy `user:<username>` 仅保留兼容监听。
- 生产撤回必须执行完整级联删除，宠物奖励和提醒投递必须事务幂等。

## 5. 验证基线

后端改动至少执行：

```powershell
cd server
npm test
npm run build
```

iOS 改动通过 GitHub Actions 验证 SwiftLint、结构护栏、iPhone 单测、必要的 iPad build、unsigned Archive 和 IPA 打包。真机视觉、手势、蓝牙音频和双设备行为仍由设备回归确认。

## 6. 下一步优先级

1. 将 Agent/MCP/Memory runtime 从 legacy 字符串上下文迁移到 `conversation_id/account_id/couple_id`。
2. 完成 `sync:available`、偏好设置云同步和 cursor 过期重建。
3. 执行 iPad 与双设备真机矩阵，补齐聊天双栏、拖放和键盘交互。
4. 补 Live Photo 配对资源协议与原生预览。
5. 在隔离环境完成 v10 → v24 备份、恢复和回滚演练。

## 7. 代码质量现状

- 2026-07-14 已完成第一轮逻辑去重：消息插入/批量合并/ACK 替换共用同一实现，并修复早期消息错误追加到窗口末尾以及 Socket/ACK 竞态产生重复消息的问题。
- 文字、媒体和贴纸发送共用待发草稿工厂；完整历史同步与已读回执已从 `MessageStore` 分离。
- 客户端授权请求已开始统一到 `APIRequestFactory`；设备、日常内容和个人事项不再各自复制请求构造代码。
- 公开注册、情侣空间创建/加入、邀请码生成、客户端配对分流和对应测试已删除；v24 会停用非 `xu/si` 账号、撤销其会话并删除邀请码表。
- 已删除未接入任何入口的旧推荐弹窗/编辑器/模型，以及没有调用方的 UIKit 设计令牌。
- 本轮没有修改聊天页面约束、气泡布局公式、键盘/表情面板联动、滚动锚点或媒体预览转场。

仍需保持克制的热点是 `ChatNativeMessageCell` 和 `ChatComposerView`：它们虽然较大，但直接决定真机视觉与手势，后续拆分必须由视觉夹具和真机回归驱动，不能只为缩短文件而拆。

## 8. 修改完成定义

- 代码目录和类型命名与所属产品领域一致。
- 协议变化同时更新服务端契约、Swift 契约、`../architecture/API.md` 和测试。
- 行为、命令、部署或数据结构变化同步更新对应现行文档。
- 不提交密钥、生产数据、媒体副本、数据库备份或构建产物。
