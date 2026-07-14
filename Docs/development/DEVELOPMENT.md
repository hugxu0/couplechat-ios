# 开发指南

## 环境要求

- Windows 11 + PowerShell、Node.js、npm、SSH：可开发和验证服务端
- macOS + Xcode 26.3、XcodeGen：可本地构建最低版本为 iOS 26 的客户端
- GitHub Actions：当前 Windows 开发流程的 iOS 构建入口

服务端依赖安装：

```powershell
cd server
npm install
```

## 数据库调试

当前工作树要求 schema v25；生产发布必须先备份并使用独立 migrator 从 v24 升级，Web 进程保持 `RUN_MIGRATIONS=false`。不要用当前工作树运行 `npm run dev:cloud-db` 直连生产，版本不匹配时服务会安全退出，不会自动迁移。

生产环境只允许做只读连接检查：

```powershell
cd server
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/dev-cloud-db.ps1 -CheckOnly
```

功能调试应使用从备份恢复的隔离 PostgreSQL，再显式运行 `npm run migrate`。生产隧道脚本不会打印或保存数据库密码，并固定使用：

```env
CLOUD_DB_DEBUG=true
RUN_MIGRATIONS=false
SCHEDULED_JOBS_ENABLED=false
UPLOADS_WRITABLE=false
PUSH_ENABLED=false
```

`-CheckOnly` 只读取表计数并关闭 SSH 隧道。任何需要写聊天、共享状态或 AI Memory 的调试，都必须在隔离恢复库执行。

AI key 和模型配置放在被 Git 忽略的 `server/.data/production-ai.env`。该文件只能保存在受信开发机，不得写入文档或提交。

## AI 调试页

在 schema 已迁移到 v25 的隔离调试库运行服务后访问：

```text
http://127.0.0.1:8080/ai-debug
```

页面可切换账号和频道，查看 Agent/MCP Trace、当前 Memory 及证据，也能手动整理 Memory。页面会写入所连接的数据库，因此只能连接隔离调试库，清除消息操作不可当作普通测试清理工具使用。

## 后端日常验证

```powershell
cd server
npm test
npm run build
npm run healthcheck -- https://hoo66.top
```

- `npm test`：TypeScript 类型检查和 PostgreSQL 核心冒烟测试。
- `npm run build`：生成 `dist/`，验证生产编译。
- `npm run healthcheck`：检查数据库健康和固定账号列表。

测试必须使用临时数据库或只读生产检查。不要在自动测试中删除、批量修改生产数据或写入生产媒体。

## iOS 构建

Mac 本地：

```bash
xcodegen generate
xcodebuild test -project CoupleChat.xcodeproj -scheme CoupleChat \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

GitHub Actions 按职责拆成两条互不依赖的流程：

- `项目质量验证`：在 `main` 的 push / pull request 或手动触发时运行。服务端执行 test/build；客户端执行 SwiftLint、新 Swift 文件结构护栏、iPhone 单元测试和 iPad 编译。它不归档、不生成 IPA。
- `构建 IPA`：仅手动触发。它只安装 XcodeGen、生成工程、执行 Release unsigned Archive、打包并上传 `CoupleChat-latest.ipa` 和 SHA-256 文件，不运行服务端测试、SwiftLint、模拟器测试或视觉截图。

两条流程固定使用 Xcode 26.3。质量验证只在失败时上传诊断；IPA 流程的 artifact 固定名为 `CoupleChat-latest`，本机可继续使用 `.github/scripts/download-latest-ipa.ps1` 覆盖到固定路径。

```powershell
# 自动下载最近一次成功构建，并覆盖固定文件
.\.github\scripts\download-latest-ipa.ps1

# 如需回取指定历史构建
.\.github\scripts\download-latest-ipa.ps1 -RunId 123456789
```

生成的 `.xcodeproj`、`build/` 和 `build-artifacts/` 不提交。

下载脚本只选择成功完成的 `main` 构建，并覆盖固定 IPA 与 SHA-256 文件。手动指定 Run ID 时也应先确认该运行的 `headSha` 是准备安装的提交，不能用仍在运行或失败的 artifact 覆盖当前可安装包。

### 本地 `build-artifacts/` 保留策略

该目录只服务本机安装与排障，不进入 Git。建议只保留：

- 固定路径的当前 IPA：`CoupleChat-latest.ipa`
- 与生产对应的 server 镜像 tar / 回滚相关包
- 如需对照，最多保留 1 份最近 GitHub run 下载物

中间编号的 IPA、重复的 github-run 目录和过期诊断包应及时删除，避免把本地缓存误当成发布真相。

## 开发约定

- 新页面观察真正拥有状态的对象：聊天窗口用 `ChatTimelineStore`，共享状态用 `SharedStore`，账号用 `AuthStore`。
- SQLite 只能通过异步 `ChatPersistenceProtocol` 访问；不得在 MainActor、页面或控制器中调用 `ChatLocalDatabase.shared`。
- 每日内容、提醒/备忘、统计/存储分别使用对应 Repository，避免继续扩大 `ChatStore`。
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

- 颜色、圆角、间距、字体、动画、阴影只从 `Sources/DesignSystem/DS.swift` 取值；页面内不要再写散落魔法数。
- 常规文案用 `DS.Typo.body/secondary/caption/button/sectionLabel/micro`；大数字用 `displayHero/displayMetric/displayNumber`；装饰性巨型图标可保留固定字号。
- 内容卡片用 `dsCard()` / `AppCard`；浮动层（Tab 栏、输入栏、浮钮）用 `dsGlass` / `dsGlassInteractive`。
- 动画优先 `DS.Anim.*`，需要尊重「减少动态效果」时用 `DS.Anim.withMotion` 或 `DS.Anim.motion`。
- 语义组件放在 `AppSemanticComponents.swift`：`RootPageHeader`、`AppSectionHeader`、`AppPrimaryButton`、`StatusBanner`、`AppEmptyState` 等；重复样式先抽组件再改页面。
- 聊天 UIKit 路径需要同一数值时读 `DS.UIKitToken`，避免 SwiftUI / UIKit 各写一套。
- Apple 设计上下文见 `.claude/apple-design-context.md`（气质：温暖、成熟、克制地使用材质；聊天发送、键盘、贴底和媒体手势可靠性优先）。

## 提交前检查

```powershell
git status --short
git diff --check
cd server
npm test
npm run build
```

iOS 改动还需确认对应 GitHub Actions 通过。
