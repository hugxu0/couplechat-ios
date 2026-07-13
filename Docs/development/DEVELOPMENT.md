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

当前生产已执行到 v23，而本工作树同样要求 v23；仍不要用当前工作树运行 `npm run dev:cloud-db` 直连生产：Web 进程已经强制 `RUN_MIGRATIONS=false`，会因 schema 版本不匹配安全退出，不会自动迁移。

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

在 schema 已迁移到 v23 的隔离调试库运行服务后访问：

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

### 本地 `build-artifacts/` 保留策略

该目录只服务本机安装与排障，不进入 Git。建议只保留：

- 当前正式发布候选 IPA（例如 `CoupleChat-unsigned-230`）
- 最近一次可用维护构建 IPA（例如 `CoupleChat-unsigned-247`）
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

### 设计系统约定

- 颜色、圆角、间距、字体、动画、阴影只从 `Sources/DesignSystem/DS.swift` 取值；页面内不要再写散落魔法数。
- 常规文案用 `DS.Typo.body/secondary/caption/button/sectionLabel/micro`；大数字用 `displayHero/displayMetric/displayNumber`；装饰性巨型图标可保留固定字号。
- 内容卡片用 `dsCard()` / `AppCard`；浮动层（Tab 栏、输入栏、浮钮）用 `dsGlass` / `dsGlassInteractive`。
- 动画优先 `DS.Anim.*`，需要尊重「减少动态效果」时用 `DS.Anim.withMotion` 或 `DS.Anim.motion`。
- 语义组件放在 `AppSemanticComponents.swift`：`RootPageHeader`、`AppSectionHeader`、`AppPrimaryButton`、`StatusBanner`、`AppEmptyState` 等；重复样式先抽组件再改页面。
- 聊天 UIKit 路径需要同一数值时读 `DS.UIKitToken`，避免 SwiftUI / UIKit 各写一套。
- Apple 设计上下文见 `.claude/apple-design-context.md`（气质：温柔玻璃感；聊天可深度统一样式，但发送/键盘/贴底可靠性优先）。

## 提交前检查

```powershell
git status --short
git diff --check
cd server
npm test
npm run build
```

iOS 改动还需确认对应 GitHub Actions 通过。
