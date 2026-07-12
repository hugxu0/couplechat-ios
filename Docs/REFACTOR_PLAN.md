# 客户端体验与整体架构优化计划

> 状态：主体功能已上线；R5.3/R5.4 继续收敛，R8.1 双设备/iPad 真机矩阵待补
>
> 适用范围：iOS 客户端、Node.js 服务端、GitHub Actions 交付链路
>
> 产品约束：仅两位固定用户；设备均为 iPhone 17 / iPad 最新系统；允许重新登录和清空本地 SQLite；服务端聊天历史必须保留；AI、记录、提醒等已完成功能必须继续可用；宠物页暂不投入重构。

## 1. 结论

项目不需要推倒重写。当前服务端的消息、媒体、AI 和数据库主链路已有较好的基础，客户端的 Telegram 式聊天骨架也基本成立。主要问题是客户端边界持续膨胀、视觉实现存在多套并行方案、页面生命周期错误地拥有长任务，以及关键交互缺少自动化验收。

本计划采用“先建立护栏，再逐个替换高风险部件”的方式：

1. 不动已经顺手的键盘与输入栏链路。
2. 先修同步和失败消息等确定性 Bug。
3. 聊天顶部改为单一原生材质系统，不再调多层透明度碰运气。
4. 媒体浏览增加真正的共享元素转场和交互式退出。
5. 在行为稳定后拆分 `ChatViewController`、`MessageStore`、`ChatStore` 和 SQLite。
6. 最后统一聊天以外页面的设计语言，再整理后端模块。

### 1.1 任务状态表

状态只能使用“待执行 / 进行中 / 已验收 / 阻塞”。代码写完但没有通过本任务验收时，仍然是“进行中”。当前唯一允许直接开始的任务是 R0.1。

| 阶段 | 任务 | 状态 | 前置任务 |
|---|---|---|---|
| 0 | R0.1 建立 Bug/体验基线 | 已验收 | 无 |
| 0 | R0.2 改造 GitHub Actions | 已验收 | R0.1 |
| 0 | R0.3 确认 iOS 26 最低版本 | 已验收 | R0.2 |
| 1 | R1.1 同步任务移出页面 | 已验收 | R0.3 |
| 1 | R1.2 失败消息重试与删除 | 已验收 | R1.1 |
| 2 | R2.1 顶部视觉 Fixture | 已验收 | R1.2 |
| 2 | R2.2 原生导航栏 Spike | 已验收 | R2.1 |
| 2 | R2.3 替换聊天顶部 | 已验收 | R2.2 |
| 3 | R3.1 媒体 Viewer 协调器 | 已验收 | R2.3 |
| 3 | R3.2 交互式下拉退出 | 已验收 | R3.1 |
| 3 | R3.3 统一其他媒体入口 | 已验收 | R3.2 |
| 4 | R4.1 纯时间线构建器 | 已验收 | R3.3 |
| 4 | R4.2 滚动策略状态机 | 已验收 | R4.1 |
| 4 | R4.3 消息动作提供器 | 已验收 | R4.2 |
| 4 | R4.4 ChatTimelineController | 已验收 | R4.3 |
| 5 | R5.1 Repository/Persistence 协议 | 已验收 | R4.4 |
| 5 | R5.2 SQLite 单一所有者 | 已验收 | R5.1 |
| 5 | R5.3 拆分 MessageStore | 进行中 | R5.2 |
| 5 | R5.4 缩小 ChatStore | 进行中 | R5.3 |
| 6 | R6.1 扩充设计系统 | 已验收 | R5.4 |
| 6 | R6.2 逐页迁移 | 已验收 | R6.1 |
| 7 | R7.1 拆分后端测试 | 已验收 | R6.2 |
| 7 | R7.2 拆分数据库模块 | 已验收 | R7.1 |
| 7 | R7.3 降低业务耦合 | 已验收 | R7.2 |
| 7 | R7.4 可观测性与性能 | 已验收 | R7.3 |
| 8 | R8.1 发布前矩阵 | 进行中 | R7.4 |
| 8 | R8.2 上线与回滚准备 | 已验收 | R8.1 |

每次任务验收后，执行 AI 必须在同一个提交中更新这一行状态；不得提前批量标记后续任务。

## 2. 已确认的结构性问题

| 问题 | 当前证据 | 影响 | 处理方向 |
|---|---|---|---|
| 聊天顶部不是单一系统 | `ChatV2Screen` 同时包含壁纸亮度采样、条件顶层 blur、手工黑白文字、文字阴影、标题胶囊和自定义 Liquid Glass | 调一个参数会破坏另一个状态，浅色/暗色壁纸结果不稳定 | 首选真正的系统导航栏/Toolbar；标题、材质、按钮由同一个原生容器负责 |
| 设置子页顶部更自然 | `StorageView`、`ThemeStyleView` 等使用系统 NavigationBar | 已有可复用的正确参照 | 聊天顶部向设置子页靠拢，而不是继续复制模糊层 |
| 媒体预览没有连续转场 | `MediaPager` 由 `fullScreenCover` 打开；下拉手势只在 `onEnded` 时关闭 | 打开是突然出现，退出不跟手，也不会回到原消息中的图片 | UIKit 自定义转场 + SwiftUI 媒体内容；保留分页、缩放、收藏和下载 |
| 同步任务属于页面 | `StorageView` 在 `onDisappear` 中取消 `operationTask` | 离开存储页面同步立即停止 | App/Store 级 `HistorySyncCoordinator` 持有任务，页面只显示和控制状态 |
| 失败媒体没有完整操作 | 当前只提供点击重试；没有删除失败 outbox 的业务 API | 无法删除；本地文件缺失时重试没有明确结果 | 为 outbox 增加 retry/discard/不可重试状态和原子清理 |
| 聊天控制器职责过多 | `ChatViewController.swift` 约 1400 行，包含布局、滚动、附件、菜单、语音、贴纸和发送 | 小改动容易影响滚动或键盘 | 先抽纯逻辑，再引入 Timeline/Composer/Media 协调器 |
| Store 边界失效 | `ChatStore` 兼容转发大量功能；`MessageStore` 同时负责 UI 状态、网络、SQLite、上传和 outbox | 状态来源不清晰，页面刷新和并发难推理 | Feature Store + Repository + Service 三层渐进迁移 |
| 主线程数据库访问 | `MessageStore` 是 `@MainActor`，但仍有直接同步 SQLite 调用 | 大历史、媒体统计或慢设备可能卡 UI | SQLite 由单一 actor/串行执行器拥有 |
| CI 护栏偏弱 | SwiftLint 关闭文件长度、类型长度、函数长度和复杂度；没有 UI Test | 大文件继续增长，视觉回归只能真机碰运气 | 引入 lint baseline、新文件严格规则、视觉 Fixture 与 UI Test |
| 后端测试集中 | 核心检查集中在单个 PostgreSQL smoke 脚本 | 失败定位慢，模块边界难调整 | 保留 e2e smoke，同时按领域拆单元/集成测试 |

## 3. 目标与非目标

### 3.1 必须达到

- 发送、接收、已读、撤回、回复、搜索定位、离线 outbox 和 AI 行为不能退化。
- 键盘弹起/收起和输入栏当前手感保持不变，除非有明确复现 Bug。
- 离开存储页面后，历史同步仍继续；用户可以主动暂停；重新打开页面能看到同一任务状态。
- 失败文字、图片、视频、语音、文件和 Live Photo 都能明确地“重试”或“删除”。
- 聊天顶部在所有内置壁纸、自定义明暗壁纸、浅色/深色外观下使用同一套原生材质和文字策略。
- 图片打开、下拉退出、取消退出均连续跟手；退出时尽可能回到原消息位置。
- 其他主要页面使用统一的页面骨架、字体、间距、表面和状态反馈。
- GitHub Actions 能验证构建、单元测试、关键 UI 流程并上传可检查的截图/结果包。
- 服务端生产数据和 AI Memory 不丢失，数据库迁移只追加。

### 3.2 本轮不做

- 不重写 AI Agent、Memory 或 MCP。
- 不更换 Socket.IO、Fastify、PostgreSQL。
- 不把聊天时间线重新改回纯 SwiftUI。
- 不新增 Android/Web 客户端。
- 不投入宠物数值、动作和持久化系统。
- 不为了“架构漂亮”一次性替换所有 Store 或所有 SQLite 调用。

## 4. 设计方向

### 4.1 产品定义

- 对象：只属于两个人的长期聊天空间。
- 核心任务：快速打开、立即看到最新状态、自然发送和回看共同内容。
- 体验基底：Telegram 的清晰、克制和手势连续性，加上很轻的双人专属感。
- 原则：系统原生材质负责层级，内容和两个人的状态负责个性；不让渐变、玻璃和大圆角同时抢注意力。

### 4.2 视觉 Token

以下是默认语义，不要求所有页面硬编码这些颜色；实现时必须放入设计系统并提供深色动态色：

| Token | 默认参考 | 用途 |
|---|---|---|
| `canvas` | `#F2F2F7` | 系统分组背景 |
| `surface` | `#FFFFFF` | 列表、卡片和输入表面 |
| `ink` | `#1C1C1E` | 主要文字 |
| `xuAccent` | `#4F8FF7` | 小旭的轻量身份色 |
| `siAccent` | `#F45B7A` | 小偲的轻量身份色 |
| `dajuAccent` | `#F2A23A` | AI 状态和入口，不用于普通警告 |

字体只使用系统字体，保持原生：

- 标题：SF Pro Display，系统 `.headline` / `.title2` 对应等级。
- 正文与按钮：SF Pro Text，使用 Dynamic Type 语义样式。
- 数字、纪念日和少量情侣统计：SF Rounded；这是点缀，不扩散到聊天正文。

### 4.3 唯一的辨识点

采用“成对回声”作为唯一签名元素：在双方共同状态、在线状态、纪念日等少量位置使用蓝/粉两个小色点或一条双色细线。不要把双色渐变铺满每张卡片，也不要给所有按钮增加玻璃。

### 4.4 页面结构

```text
聊天页
┌──────────────────────────────┐
│ 原生导航材质：返回  名称/状态 头像 │  ← 单一系统，不再叠标题胶囊
├──────────────────────────────┤
│                              │
│          消息时间线           │  ← 可在导航材质后滚动并被真实采样
│                              │
├──────────────────────────────┤
│    保留现有键盘/输入栏系统      │
└──────────────────────────────┘

普通功能页
┌──────────────────────────────┐
│ 原生 NavigationBar：标题/操作   │
├──────────────────────────────┤
│ 页面摘要（只有确实需要时出现）    │
│ 系统列表或少量语义卡片            │
│ 空状态/错误状态/操作反馈           │
└──────────────────────────────┘
```

自检结果：原方案容易落入“半透明渐变 + 大圆角 + 到处玻璃”的 AI 默认风格。本方向主动删除聊天标题胶囊和大部分装饰性玻璃，把视觉风险只放在“成对回声”这个与两位用户真实相关的细节上。

## 5. 目标代码架构

这是最终方向，不允许在一个提交中一次性建完。

```text
AppContainer
├─ SessionStore                    登录与当前身份
├─ RealtimeConnectionCoordinator   Socket 生命周期、在线状态
├─ HistorySyncCoordinator          与页面无关的长同步任务
├─ ChatRepository                  消息事实源、分页、已读、发送入口
│  ├─ ChatRemoteDataSource         REST + Socket 请求
│  ├─ ChatPersistence actor        SQLite、outbox、游标
│  └─ OutboxProcessor actor        串行上传、发送、重试、丢弃
├─ PersonalItemsRepository         提醒、备忘
└─ SharedStateRepository           纪念日与共享状态

ChatScene
├─ ChatScreen / ChatViewModel      页面级可观察状态
├─ ChatViewController              生命周期与子组件装配
├─ ChatTimelineController          diff、cell、滚动锚点、加载边界
├─ ChatComposerCoordinator         输入模式、回复、附件预发送
├─ ChatMediaViewerCoordinator      媒体打开/关闭和交互式转场
└─ ChatMessageActionProvider       复制、回复、撤回、重试、删除
```

依赖只能从 UI 指向领域接口，再指向数据实现。数据层不得 import 页面类型；`ChatViewController` 不得直接访问 SQLite 或拼 REST URL。

## 6. 执行规则

后续执行 AI 每次只能领取一个编号任务。

1. 一个任务一个提交；不要同时顺手改另一个页面。
2. 开始前先运行 `git status --short`，存在不相关改动时不得覆盖。
3. Bug 修复先补可复现测试或测试夹具，再修改实现。
4. 纯拆文件任务不得改变界面、协议、数据库 schema 或运行结果。
5. UI 任务不得顺手修改 Socket、outbox、同步算法。
6. 协议任务必须同时检查服务端契约、Swift 契约、`Docs/API.md` 和契约测试。
7. 不得删除 AI 功能、Memory 表、MCP 工具或 AI 私聊隔离。
8. 不得修改已经执行过的 PostgreSQL migration；只能追加新版本。
9. 不得用固定延迟 `asyncAfter` 掩盖生命周期或动画问题；确需等待转场完成时使用 transition coordinator/completion。
10. 不得通过继续增加亮度阈值、阴影和 tint 分支修聊天顶部。
11. 每个任务结束必须运行 `git diff --check`、后端验证，以及对应 iOS GitHub Actions。
12. 真机无法本地验证的视觉任务，必须让 CI 上传截图或测试结果包，不能只声明“应该正常”。

## 7. 分阶段任务

### 阶段 0：冻结基线与建立护栏

#### R0.1 建立 Bug/体验基线

目标：防止重构时把已有好行为弄坏。

- 在 `Docs/PROJECT_STATUS.md` 增加“本轮重构基线”小节，记录：
  - 键盘弹起和收起当前是保护行为。
  - 聊天顶部、媒体转场、同步生命周期、失败媒体操作是已确认问题。
  - AI、记录、提醒、互动特效必须保留。
- 为以下纯逻辑补测试：
  - timeline diff 后保持底部/保持阅读锚点的判定。
  - pending message 使用稳定 `clientId` 定位。
  - outbox 恢复时 failed/pending 状态投影。
- 不在此任务修改 UI。

验收：现有 49 个 Swift 单元测试继续通过，新测试能在旧实现上描述现状或暴露明确缺口。

#### R0.2 改造 GitHub Actions 为可诊断交付链路

- 保留当前 unsigned IPA artifact。
- 测试命令增加 `-resultBundlePath`，无论成功或失败都上传 `.xcresult`。
- 输出并保存 `xcodebuild -version`、可用 Simulator 和 SDK 信息。
- 首次绿灯后，把工作流从浮动 `latest-stable` 固定到 CI 已安装且支持 iOS 26 SDK 的明确 Xcode 小版本。
- 新增独立 backend job：`npm ci`、`npm test`、`npm run build`。
- 旧文件继续使用现有 SwiftLint 规则；新增 Swift 文件额外启用严格结构配置，不能新增 `file_length`、`type_body_length`、`function_body_length`、`cyclomatic_complexity` 违规。这样不让旧债务导致全仓红灯，同时所有新文件从第一天受约束。

验收：一次 workflow 能分别看出 lint、Swift tests、Archive、server tests 哪一步失败，并能下载 xcresult 与 IPA。

#### R0.3 确认 iOS 26 最低版本

前置：R0.2 已确认 runner 有 iOS 26 SDK。

- 将 `project.yml` deployment target 调整为 iOS 26。
- 先只调整目标版本，不在同一任务删除全部 `#available` 分支。
- Archive 和两种尺寸 Simulator 测试通过后，再记录为项目约束。

验收：iPhone 与 iPad destination 均能编译；现有键盘、相册、录音权限声明不变。

### 阶段 1：先修确定性功能 Bug

#### R1.1 同步任务移出 `StorageView`

新建建议：`Sources/Core/Sync/HistorySyncCoordinator.swift`。

实现要求：

- `HistorySyncCoordinator` 由 App/`ChatStore` 长期持有，而不是由 `StorageView` 的 `@State` 持有。
- coordinator 暴露可观察状态：`idle`、`running(channel,current,total)`、`paused`、`completed(summary)`、`failed(message)`。
- `start()` 重复调用不得创建第二个同步任务。
- 页面退出不取消任务；显式点“暂停”、登出或账号切换才取消。
- 重新进入 `StorageView` 必须显示当前进度。
- App 被系统挂起时不承诺无限后台执行；重新打开后依靠 SQLite 中最早时间戳继续。文案写“离开此页面会继续；App 被系统暂停后，下次从进度继续”。
- 删除 `StorageView` 中第二个用于 cancel 的 `onDisappear`。
- 页面不得自己维护另一套 `SyncOperation` 真相。

测试：

- 模拟慢 worker，销毁/重建 View 状态后 coordinator 仍 running。
- 连点两次开始只调用一个 worker。
- pause 后状态正确，resume 从 repository 提供的现有游标继续。
- logout 会取消。

验收：开始同步后返回“我的”，等待一段时间再进入，计数继续增长而不是显示暂停。

#### R1.2 失败消息重试与删除闭环

修改重点：`MessageStore`、`ChatLocalDatabase`/后续 persistence、`ChatViewController` 菜单、相关测试。

新增领域操作：

```swift
enum OutboxRetryResult {
    case started
    case missingLocalFile
    case notFound
}

func retryFailedMessage(clientId: String) async -> OutboxRetryResult
func discardFailedMessage(clientId: String) async
```

实现要求：

- 所有定位优先使用 `message.clientId`，为空时才回退 `message.id`。
- discard 顺序：读取 pending 记录 → 删除 outbox 行 → 从内存时间线删除 optimistic 气泡 → 尽力删除单媒体和附件本地临时文件。
- 文件删除失败只记非敏感日志，不把已删除气泡恢复出来。
- 对已经上传但未绑定消息的远端 upload，不在客户端猜测删除；继续交给服务端过期附件清理。
- retry 前检查所有所需本地文件。缺文件时保持 failed，并明确提示“原文件已不存在，可删除后重新选择”。
- failed 消息菜单至少有“重新发送”和“删除”；删除为 destructive 并确认。
- 普通已发送消息的撤回逻辑保持原样；不要把“删除失败气泡”和服务端“撤回”混成一个 API。
- 文字、单图、视频、语音、文件、多附件 Live Photo 分别覆盖。

测试：

- 删除 failed text 清除 outbox 和内存消息。
- 删除 failed media 清除 outbox 和临时文件。
- 删除 Live Photo 清除 photo/pairedVideo 两个文件。
- 缺文件重试返回 `missingLocalFile`，不把状态改成 pending。
- 同一个 clientId 连续删除两次安全且不崩溃。

验收：真机断网发送图片产生失败气泡；长按可重试或删除；恢复网络后重试只出现一条服务端消息。

### 阶段 2：重建聊天顶部材质系统

#### R2.1 建立可重复的聊天顶部视觉 Fixture

- 抽出只依赖值类型的 `ChatHeaderModel`：标题、副标题、头像、连接状态、是否 AI 输入。
- 新建 DEBUG-only `ChatHeaderVisualFixtureScreen`，通过 launch arguments 选择：
  - 内置最亮壁纸；
  - 内置最暗壁纸；
  - 高对比自定义图片；
  - 浅色外观；
  - 深色外观；
  - connecting/failed/online/AI composing 状态。
- Fixture 不能登录生产账号、不能访问生产服务。
- 增加 UI Test 启动 Fixture 并截图，Actions 上传截图 artifact。

验收：在没有账号和网络的 CI Simulator 中，可以稳定产出顶部截图。

#### R2.2 原生导航栏方案 Spike

当前选择：方案 A。DEBUG Fixture 使用系统 `NavigationStack`、默认返回按钮、principal 标题/状态和
trailing 头像；方案 B 未进入产品代码。最终判定与 R2.3 合并进行阶段 2 截图和真机验收。

只做两种最小原型，不同时保留到产品代码：

- 方案 A（首选）：SwiftUI `toolbar` / 系统 `UINavigationBar`，系统返回按钮、principal 标题/状态、trailing 头像；使用系统默认 iOS 26 材质。
- 方案 B（仅 A 无法满足布局时）：UIKit `UINavigationBar` + `UINavigationBarAppearance` 的系统 background effect。仍然只允许一个原生 bar，不允许手绘多层 blur。

判定标准：

- 壁纸/消息滚动到顶部后，材质采样连续，没有静态白蒙层。
- push、interactive pop、旋转/尺寸变化无白闪。
- 标题、副标题、图标在视觉 Fixture 全部可读。
- online/connecting/failed 状态颜色符合系统语义。
- 不依赖自定义壁纸全局中位亮度阈值。

若 A 通过，删除 B 原型；若 A 不通过，在任务说明中列出可复现限制后选择 B。禁止凭主观同时混用。

#### R2.3 替换现有聊天顶部

- 删除聊天顶部专用的 `topSafeGlass`、`TopBackdropBlur`、手工文字阴影和顶部亮度切色。根据真机反馈，principal 标题保留系统 `Toolbar` 内的单层交互式 Capsule Glass；它不是第二层顶部 backdrop。
- `ChatSurfaceTone` 如果仍被 composer 使用，只保留 composer 职责并改名，不能继续控制顶部。
- 顶部标题、状态和头像进入 R2.2 选定的同一个系统导航容器。
- 时间线可滚到导航材质后方；当前 UIKit 时间线使用系统安全区加标准 44pt 导航内容高度计算 overlay inset，不再维护旧的自定义 58pt 标题层。
- 保留现有输入栏、键盘 observer、底部 inset 和 composer tone 逻辑，不在此任务重做。
- 保留 interactive pop。

视觉验收矩阵：

| 场景 | 要求 |
|---|---|
| 最亮内置壁纸 | 标题清楚，顶部不是整块白雾 |
| 最暗内置壁纸 | 标题清楚，图标不消失 |
| 黑白交错自定义壁纸 | 滚动时不频繁闪黑/闪白 |
| online → reconnecting | 只有状态内容变化，材质不跳 |
| push/pop | 首帧没有默认白色 blur 闪烁 |
| iPad 宽屏 | 标题仍居中，左右按钮不漂移 |

### 阶段 3：Telegram 式媒体转场

#### R3.1 拆出媒体 Viewer 协调器

建议新增：

```text
Sources/Features/Chat/MediaViewer/
  ChatMediaViewerCoordinator.swift
  MediaViewerTransitionAnimator.swift
  MediaViewerInteractionController.swift
  MediaViewerHostController.swift
```

- `MediaPagerView` 继续负责媒体分页、图片缩放、视频、收藏、下载和预取。
- `ChatMediaViewerCoordinator` 负责 UIKit present/dismiss 与转场，不让 `ChatV2Screen` 用 `fullScreenCover` 打开聊天媒体。
- Cell 提供当前媒体 ID、可见源视图/源 frame 和 snapshot；相册消息必须返回当前页图片，而不是整个气泡。
- 源 cell 已离屏时使用缩放淡出 fallback，不能崩溃。

验收：先实现非交互式打开/关闭；打开从气泡图片 frame 放大到 aspect-fit，关闭回原 frame。

#### R3.2 增加交互式下拉退出

- 使用 pan gesture 连续驱动 translation、scale 和黑色背景 alpha。
- 完成阈值同时考虑竖直位移和速度；未达到阈值时弹回原位。
- 图片缩放比例大于 1 时，优先交给图片平移，不触发退出。
- 横向翻页手势优先于退出；只有竖直意图明确后才接管。
- 手势过程中不得等到 `onEnded` 才改变画面。
- 当前页变化后，退出目标使用当前 item；找不到当前 item 的源视图则 fallback。
- 视频播放在开始退出时暂停，取消退出后按原状态恢复。

可测试的纯逻辑：完成阈值、背景 alpha、scale clamp、横竖手势判定。

真机验收：慢拖、快甩、拖一半取消、放大图片后拖动、横向翻页、视频退出六种场景都连续。

#### R3.3 统一其他媒体入口

- 聊天入口稳定后，再让 `MediaGallery` 和收藏媒体页复用同一 Viewer。
- SwiftUI 网格无法提供 UIKit 源视图时，可以使用系统 zoom transition 或统一 fallback；不得复制第二套 Pager。
- 删除旧 `fullScreenCover` 路径和旧 dismiss gesture。

### 阶段 4：缩小聊天页面职责

此阶段每个任务必须是行为保持型重构。

#### R4.1 抽出纯时间线构建器

- 新建 `ChatTimelineBuilder`，输入 messages、AI activity、分组规则，输出 `[ChatTimelineItem]`。
- 移出时间分隔、连续发送者分组、消息 ID 映射等纯逻辑。
- 给跨午夜、系统消息、AI activity、相同时间戳、pending 替换正式消息补测试。

#### R4.2 抽出滚动策略状态机

- 用值类型 `ChatScrollState` / `ChatScrollDecision` 表达：初次定位、用户在底部、浏览旧窗口、加载更旧、加载更新、收到新消息、跳转搜索结果。
- 将“是否滚底/是否保锚点/是否显示回到底部按钮”的判定从 controller 中抽出并测试。
- UIKit 只执行决策，不再散落多组 Boolean 互相覆盖。

#### R4.3 抽出消息动作提供器

- `ChatMessageActionProvider` 根据消息状态生成允许动作：copy/reply/recall/re-edit/retry/discard。
- Controller 只把动作映射为 `UIAction`。
- failed、pending、system、other-user、超过两分钟等矩阵有测试。

#### R4.4 建立 `ChatTimelineController`

- 迁移 collection view data source、cell 配置、diff/reload、滚动锚点、上下拉加载。
- `ChatViewController` 只装配 header、timeline、composer、media coordinator。
- 不要仅把代码复制到多个 extension 后把所有属性从 private 改成 internal；新对象必须拥有自己的状态。

阶段验收：`ChatViewController.swift` 小于 500 行；键盘与 composer 文件没有无关改动；所有关键聊天行为通过 UI Test。

### 阶段 5：整理状态、网络和本地数据边界

#### R5.1 引入协议边界

- 定义 `ChatRepositoryProtocol`、`ChatPersistenceProtocol`、`OutboxProcessing`。
- 先让现有 `MessageStore` 背后适配这些协议，不立刻改所有调用者。
- `ChatViewController`/ViewModel 只接触 repository/store 的领域方法。

#### R5.2 SQLite 单一所有者

- 让一个 actor 或严格串行 executor 独占 SQLite connection。
- 所有消息、已读、shared state、outbox 查询通过 async API。
- 移除 `@MainActor` 内直接 `ChatLocalDatabase.shared.*` 的同步调用。
- schema、message queries、outbox queries、stats queries 拆文件，但保持一个 connection owner。
- 因为服务端是事实源且允许清本地缓存，可以在必要时启用新本地 schema 版本；切换前必须处理/提示仍存在的 pending outbox。

测试：并发 insert/fetch、账号切换、清缓存、同步同时读统计、outbox flush 同时收到 ack。

#### R5.3 拆分 `MessageStore`

当前进度：`ChatTimelineStore`、`OutboxProcessor` 和 `MediaUploadService` 已抽出，但分页、搜索、已读和消息合并仍留在 compatibility facade 中，因此保持“进行中”。

- `ChatTimelineStore`：仅 MainActor 可观察状态和窗口。
- `ChatRepository`：分页、搜索、已读和消息合并。
- `OutboxProcessor`：串行上传/发送/重试/ack。
- `MediaUploadService`：multipart 和上传响应。
- 保留临时 compatibility facade，逐个迁移调用点；所有调用点迁完再删除。

#### R5.4 缩小 `ChatStore`

当前进度：统计、存储和 personal item 的实现已移入 repository，但 `ChatStore` 仍负责装配多个 App 级依赖和 Socket 生命周期；页面已开始直接观察 `ChatTimelineStore`，连接协调器仍待独立，因此保持“进行中”。

- 移出统计、存储空间、媒体全量缓存、personal item CRUD。
- 连接状态交给 `RealtimeConnectionCoordinator`。
- 避免父 `ObservableObject` 手工转发子 `objectWillChange`；页面观察真正拥有状态的对象。
- 最终 `ChatStore` 若仍保留，只作为 Chat feature facade，不再是全 App service locator。

### 阶段 6：统一聊天外页面

执行顺序：设计系统 → 首页 → 记录 → 提醒 → 我的/存储/主题 → 登录。宠物页跳过。

#### R6.1 扩充设计系统

建立语义组件，而不是继续堆单个数值：

- `AppPageBackground`
- `RootPageHeader`
- `AppSectionHeader`
- `AppCard`（只允许 2～3 个语义层级）
- `StatusBanner`
- `EmptyState`
- `DestructiveActionRow`
- `PairedEchoIndicator`

要求：

- 根页面使用一致的标题基线和左右留白。
- 子页面默认使用系统 NavigationBar 和 List/Form 行为。
- Glass 只用于真正浮在内容上方的导航、输入或临时控件；普通卡片用 surface。
- 页面文案使用用户能理解的动作：“继续同步”“删除失败消息”，不暴露 outbox/游标。
- 支持 Dynamic Type、VoiceOver label、Reduce Motion。

#### R6.2 逐页迁移

每页单独提交，流程固定：

1. 截取/保存旧页面 CI Fixture。
2. 列出页面信息层级和所有状态。
3. 只替换布局与语义组件，不改业务请求。
4. 补 loading/empty/error/content 四态。
5. 输出新截图，与聊天页和设置子页并排检查。

不要用一个“全 App 美化”提交同时修改五个 800 行页面。

### 阶段 7：后端渐进审计与模块化

#### R7.1 拆分测试，不改生产行为

- 保留 `smoke-postgres.ts` 作为最终 e2e。
- 增加按领域测试目录：auth、message、upload、sync、personal-items、ai-memory、ai-queue。
- 纯函数使用快速单元测试；需要数据库的测试共享临时 PostgreSQL harness。
- 测试不得连接生产数据库或发送真实 Bark/AI 请求。

#### R7.2 拆分数据库模块

建议目标：

```text
server/src/db/
  client.ts
  transaction.ts
  rows.ts
  migrate.ts
  migrations/001_initial.ts ...
  index.ts
```

- 只移动现有 migration 文本，不修改已经发布版本的 SQL。
- `index.ts` 只 re-export 稳定 API。
- 新 migration 仍追加版本号。

#### R7.3 降低业务耦合

- `messageService` 不直接调用 AI Memory 具体实现；撤回后发布领域事件，由 AI 模块订阅并失效证据。
- Socket 路由只做解析、调用 use case、emit/ack，不承载业务分支。
- 用依赖注入替代 `setSocketIO` 这类全局可变实例；先从 reminder/personal items 开始。
- shutdown 时停止 scheduler、upload cleanup、Socket.IO，再关闭数据库。

#### R7.4 可观测性与性能

- 为 send/upload/sync/AI reply 增加 requestId/clientId/channel/耗时等结构化字段，但不记录消息正文、token 或密钥。
- 固定错误码，客户端根据错误码展示可操作提示。
- 使用接近真实数量的临时消息数据对 bootstrap、before/around/search 查询执行 `EXPLAIN ANALYZE`；只有证据显示慢查询时才追加索引。
- 健康检查区分进程存活和数据库可用；部署仍可使用当前 `/health`，如有必要新增 readiness 而不是破坏旧路径。

### 阶段 8：发布、双机验证与清理

#### R8.1 发布前矩阵

两账号、iPhone/iPad 至少覆盖：

- 冷启动在线、冷启动断网、token 失效重新登录。
- 双向文字、单图、多图、Live Photo、视频、语音、文件、贴纸。
- 发送中杀 App、断网失败、恢复重试、失败删除。
- 已读、回复、撤回、搜索定位、加载更旧、返回最新。
- AI 私聊、公聊 `@大橘`、图片理解、确认卡。
- 历史同步离开页面继续、暂停、重启 App 后继续。
- 最亮/最暗/自定义壁纸下的聊天顶部。
- 图片打开、翻页、缩放、下拉取消、下拉完成。
- 记录、提醒、纪念日、主题、存储功能。

#### R8.2 上线步骤

1. 备份 PostgreSQL 和 uploads。
2. 后端变更先部署并跑 healthcheck；协议必须向旧客户端兼容。
3. 保留上一版 server image 和 IPA。
4. 两部手机同时安装新客户端。
5. 确认没有必须保留的 pending 消息后，可清空旧 SQLite 并重新同步。
6. 完成两账号互发和 AI 冒烟后再宣布完成。

回滚：客户端回上一版 IPA；服务端回上一镜像。数据库只允许 additive migration，因此不执行破坏性 down migration。

## 8. 推荐提交顺序

严格按以下顺序，未通过验收不得开始下一项：

```text
R0.1 → R0.2 → R0.3
              ↓
R1.1 → R1.2
              ↓
R2.1 → R2.2 → R2.3
              ↓
R3.1 → R3.2 → R3.3
              ↓
R4.1 → R4.2 → R4.3 → R4.4
              ↓
R5.1 → R5.2 → R5.3 → R5.4
              ↓
R6.1 → R6.2
              ↓
R7.1 → R7.2 → R7.3 → R7.4
              ↓
R8.1 → R8.2
```

R1、R2、R3 是用户最直接能感知的优先级。R4、R5 是防止未来继续“修不完”的结构治理。R6 不应抢在聊天关键体验之前。R7 不阻塞客户端视觉工作，但生产协议相关任务必须串行。

## 9. 每个执行 AI 的固定任务模板

将下面内容与单个任务编号一起交给执行 AI：

```text
你只执行 Docs/REFACTOR_PLAN.md 中的任务 Rx.x，不执行其他编号。

开始前：
1. 阅读该任务、Docs/ARCHITECTURE.md、Docs/DEVELOPMENT.md。
2. 阅读任务点名的所有现有文件和测试。
3. 运行 git status --short，保留用户已有改动。
4. 用 5～10 行复述：现状、根因、将修改的文件、不会修改的边界。

实施规则：
- 先写失败测试或稳定 Fixture，再改实现。
- 不做顺手重构，不修改无关格式。
- 不改已发布 PostgreSQL migration。
- 不删除 AI、记录、提醒或互动功能。
- 遇到需要扩大任务范围的情况立即停止并说明，不自行扩展。

完成后必须报告：
1. 修改文件清单和每个文件的职责变化。
2. 自动测试命令及完整结果。
3. GitHub Actions run 是否通过、artifact 名称。
4. 仍需人工验证的逐步操作。
5. 对照任务验收标准逐条写“通过/未通过/无法验证”。
6. 未全部通过时不得声称任务完成。
```

## 10. 全计划完成定义

- 阶段 0～8 的验收项全部完成。
- `ChatViewController.swift` 不再是多职责巨型控制器。
- 聊天顶部只有一套原生材质系统。
- 媒体 viewer 只有一个内容实现和一个转场协调入口。
- 同步、outbox 不再由页面生命周期拥有。
- UI 主线程不再同步访问 SQLite。
- SwiftLint 对新代码启用复杂度护栏。
- iOS Unit/UI Tests、Archive、server tests/build 全绿。
- 两个真实账号在两部真机完成发布矩阵。
- `PROJECT_STATUS.md`、`ARCHITECTURE.md`、`DEVELOPMENT.md` 与最终代码一致。
