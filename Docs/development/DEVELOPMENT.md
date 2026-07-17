# 开发指南

## 开工检查

```powershell
git rev-parse --show-toplevel
git status --short --branch
git rev-parse HEAD
```

必须在同时包含 `Sources/` 与 `server/` 的真实单仓库中工作。无 `.git` 的客户端/服务端复制目录只是快照，不能继续作为开发或发布事实源。先阅读根 `AGENTS.md`、[当前项目](../current/PROJECT.md) 和 [已知问题](../current/KNOWN_ISSUES.md)。

## 环境要求

- Windows 11 + PowerShell、Node.js 22、npm、SSH：可开发和验证服务端
- macOS + Xcode 26.3、XcodeGen：可本地构建最低版本为 iOS 26 的客户端
- GitHub Actions：当前 Windows 开发流程的 iOS 构建入口

服务端依赖安装：

```powershell
cd server
npm ci
```

本地运行服务需要准备非生产 `.env`，至少包含稳定的 `TOKEN_SECRET`、隔离 PostgreSQL 的 `DATABASE_URL` 和同时定义 `xu/si` 的 `COUPLECHAT_ACCOUNTS`。首次运行可显式执行：

```powershell
cd server
npm run build
npm run migrate
npm start
```

开发环境 `RUN_MIGRATIONS` 默认开启，但生产 Web 进程必须关闭；显式 migrator 更接近生产流程。

## 数据库调试

当前工作树要求 schema v31。普通代码发布不运行 migrator，也不重复完整备份恢复；只有 migration、数据修复或媒体结构变化才使用独立 migrator 和 quiesced 备份，Web 进程始终保持 `RUN_MIGRATIONS=false`。连接生产库启动本地调试服务的入口已经移除；版本不匹配时也不能用开发进程“试一下”。

功能调试只能使用本地临时 PostgreSQL，或从备份恢复的隔离 PostgreSQL，再显式运行 `npm run migrate`。隔离调试服务应固定使用：

```env
RUN_MIGRATIONS=false
SCHEDULED_JOBS_ENABLED=false
UPLOADS_WRITABLE=false
PUSH_ENABLED=false
```

任何需要写聊天、共享状态或 AI Memory 的调试，都必须在隔离恢复库执行。只读角色完成现场验收前，生产状态检查由受信运维者在服务器本机进行，不从开发机启动应用进程。

AI key 和模型配置放在被 Git 忽略的 `server/.data/production-ai.env`。该文件只能保存在受信开发机，不得写入文档或提交。

## AI 调试页

在 schema 已迁移到 v31 的隔离调试库运行服务后访问：

```text
http://127.0.0.1:8080/ai-debug
```

页面可切换账号和频道，查看 Agent/MCP Trace 与当前 Memory，也能手动整理 Memory。页面会写入所连接的数据库，因此只能连接隔离调试库，清除消息操作不可当作普通测试清理工具使用。

## 后端日常验证

```powershell
cd server
npm run check
npm run healthcheck -- https://hoo66.top
```

- `npm run check`：一次完成 TypeScript 类型检查、快速纯逻辑测试、一次 embedded PostgreSQL 当前行为烟测和生产编译。
- `npm run healthcheck`：依次检查 `/health`、`/ready` 和固定账号列表 `xu,si`。

普通服务端代码发布不再重复人工打包和远程命令；在工作树干净且 `HEAD` 已推送到 `origin/main` 后运行：

```powershell
.\server\deploy\publish-server.ps1 -SshTarget '<private-ssh-alias>'
```

脚本会执行本机唯一一次 `npm run check`。migration、数据修复、媒体结构变化或不兼容协议变更不能使用这个入口。

测试必须使用临时数据库或只读生产检查。不要在自动测试中删除、批量修改生产数据或写入生产媒体。

## iOS 构建

Mac 本地：

```bash
xcodegen generate
xcodebuild test -project CoupleChat.xcodeproj -scheme CoupleChat \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

GitHub Actions 只保留一条默认快速验证链和一个手动 IPA 流程：

- `项目快速验证`：在 `main` push、面向 `main` 的 pull request 或手动触发时运行，并在同一条流水线中完成公开仓库安全扫描。服务端执行 `npm run check`；客户端执行 SwiftLint、新 Swift 文件结构护栏和 generic iOS 编译，不启动模拟器跑 XCTest，也不重复做 iPad 编译。
- `构建 unsigned IPA`：仅手动触发，直接对当前精确 commit 执行 Release unsigned Archive，不再先重复调用快速验证。artifact 名称包含完整 SHA、run ID 和 attempt，并带 `BUILD-METADATA.json` 与 `SHA256SUMS`。它不进行 Apple 签名，也不替代真机视觉/手势验证。

所有第三方 Action 固定到完整 commit；Socket.IO Client Swift 与 GLTFKit2 固定精确版本。两个 iOS job 固定使用 Xcode 26.3。仓库目前仍缺少 `Package.resolved`，Homebrew 安装的 XcodeGen/SwiftLint 也没有锁定 formula revision，因此还不能完全复现历史依赖图。质量验证只在失败时上传诊断；IPA artifact 保留 14 天，本机下载必须提供完整 commit SHA：

```powershell
$Sha = (git rev-parse HEAD).Trim()
.\.github\scripts\download-unsigned-ipa.ps1 -Commit $Sha

# 如需限定某次重跑
.\.github\scripts\download-unsigned-ipa.ps1 -Commit $Sha -RunId 123456789

# 如需覆盖默认的桌面 CoupleChat-IPA 目录
.\.github\scripts\download-unsigned-ipa.ps1 -Commit $Sha `
  -OutputDirectory 'D:\Desktop\CoupleChat-IPA'
```

生成的 `.xcodeproj`、`build/` 和 `build-artifacts/` 不提交。

下载脚本按完整 SHA 查询成功运行，并交叉校验 workflow 文件/数据库 ID、run ID/attempt、metadata、两个 SHA-256、IPA 实际 `Info.plist`、必需资源和签名残留；全部通过后才从安全 staging 原子发布到当前用户桌面的 `CoupleChat-IPA`（本机为 `D:\Desktop\CoupleChat-IPA`），失败时保留上一份已验证目录。完整的免费签名、三台设备刷新和数据连续性流程见 [IOS_SIDELOAD.md](../operations/IOS_SIDELOAD.md)。

### 3D 模型资源

`Sources/Resources/cute_cat.glb` 已受 Git 版本控制，XcodeGen 会把它随 `Sources` 收入 App；授权见 `Sources/Resources/ThirdPartyNotices.txt`，不需要额外的本地注入步骤。文件缺失或 GLTFKit2 加载失败时仍应可运行，并结束加载动画后显示占位。

### 本地 `build-artifacts/` 保留策略

该目录只服务本机安装与排障，不进入 Git。建议只保留：

- 当前准备侧载的 `ipa/<完整SHA>/` 目录及其 metadata/checksum
- 与生产对应的 server 镜像 tar / 回滚相关包
- 如需对照，最多保留 1 份最近 GitHub run 下载物

中间编号的 IPA、重复的 github-run 目录和过期诊断包应及时删除，避免把本地缓存误当成发布真相。

## 开发约定

- 新页面观察真正拥有状态的对象：聊天窗口用 `ChatTimelineStore`，共享状态用 `SharedStore`，账号用 `AuthStore`。
- SQLite 只能通过异步 `ChatPersistenceProtocol` 访问；不得在 MainActor、页面或控制器中调用 `ChatLocalDatabase.shared`。
- 提醒/备忘、统计/存储分别使用对应 Repository，避免继续扩大 `ChatStore`。
- 网络请求通过 `HTTPClient`，Socket payload 通过 `SocketPayloadEncoder`。
- 新协议先改两端契约，再改调用点，并补契约测试。
- 新数据库字段在 `server/src/db/migrate.ts` 追加版本化变更；`index.ts` 只做稳定 re-export。
- Bug 修复优先补最小复现测试；无法自动化的真机问题写入 `../current/PROJECT.md` 的“当前限制”，修复后立即删除该条。
- 日志不得包含 token、密码、API key、完整私聊内容或数据库连接串。

### 媒体交互约定

- 可点击的图片/视频使用一个明确的 `Button` 或 UIKit control 承载轻点；不要对按钮内真正绘制内容的图片或视频设置 `allowsHitTesting(false)`。
- 全屏预览 source anchor 只能作为不接收触摸的 overlay/background 存在，不得覆盖按钮手势，也不能参与媒体单元尺寸计算。
- 细长图片可在时间线缩略图中按固定区域裁切，但裁切必须在按钮标签内部完成，不能让原图视觉层越界遮住文案、编辑按钮或相邻动态。
- 同一媒体单元的长按菜单挂在承载轻点的控件上；编辑文案是正文行的独立操作，不放进图片预览器。
- 调整相册布局后至少真机检查：轻点每个缩略图、长按媒体、编辑空/非空文案、单张细长图、多图、视频封面、左右翻页和上下拖动退出。

### 设计系统约定

- 产品视觉方向是温暖、成熟、克制地使用材质；聊天发送、键盘、贴底和媒体手势的可靠性优先于装饰效果。
- 颜色、圆角、间距、字体、动画、阴影只从 `Sources/DesignSystem/DS.swift` 取值；页面内不要再写散落魔法数。
- 常规文案用 `DS.Typo.body/secondary/caption/button/sectionLabel/micro`；大数字用 `displayNumber`；装饰性巨型图标可保留固定字号。
- 内容卡片用 `dsCard()` / `AppCard`；浮动层（Tab 栏、输入栏、浮钮）用 `dsGlass` / `dsGlassInteractive`。
- 动画优先 `DS.Anim.*`，需要尊重「减少动态效果」时用 `DS.Anim.withMotion` 或 `DS.Anim.motion`。
- 语义组件放在 `AppSemanticComponents.swift`：`RootPageHeader`、`AppSectionHeader`、`AppPrimaryButton`、`StatusBanner`、`AppEmptyState` 等；重复样式先抽组件再改页面。
- 聊天 UIKit 路径需要同一数值时读 `DS.UIKitToken`，避免 SwiftUI / UIKit 各写一套。
- 新界面必须检查深色模式、Dynamic Type、VoiceOver、Reduce Motion 和非颜色状态提示；iPad 还需检查横竖屏、Split View、Stage Manager、指针与键盘操作。当前未完成的 iPad 能力以 [PROJECT.md](../current/PROJECT.md) 为准。

## 提交前检查

```powershell
git status --short
git diff --check
cd server
npm run check
```

iOS 改动还需确认对应 GitHub Actions 通过。
