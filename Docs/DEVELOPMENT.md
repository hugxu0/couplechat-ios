# 开发指南

## 环境要求

- Windows 11 + PowerShell、Node.js、npm、SSH：可开发和验证服务端
- macOS + Xcode、XcodeGen：可本地构建 iOS
- GitHub Actions：当前 Windows 开发流程的 iOS 构建入口

服务端依赖安装：

```powershell
cd server
npm install
```

## 本地服务端调试

项目不维护本地服务端数据库。以下命令建立 SSH 隧道并运行本地代码，数据库使用 RFCHost 上的生产 PostgreSQL：

```powershell
cd server
npm run dev:cloud-db
```

脚本会从服务器运行环境读取连接串，只在当前进程中改写为本机隧道地址；不会打印或保存数据库密码。调试进程固定使用：

```env
CLOUD_DB_DEBUG=true
SCHEDULED_JOBS_ENABLED=false
UPLOADS_WRITABLE=false
PUSH_ENABLED=false
```

因此本地调试可以真实读写聊天、共享状态和 AI Memory，但不会运行定时任务、发送 Bark 或写媒体文件。退出进程会关闭 SSH 隧道。

只检查连接：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/dev-cloud-db.ps1 -CheckOnly
```

AI key 和模型配置放在被 Git 忽略的 `server/.data/production-ai.env`。该文件只能保存在受信开发机，不得写入文档或提交。

## AI 调试页

运行本地服务后访问：

```text
http://127.0.0.1:8080/ai-debug
```

页面可切换两位账号和两个频道，查看 Agent/MCP Trace、当前 Memory 及证据，也能手动整理 Memory。页面写入的是生产数据库，清除消息操作不可当作普通测试清理工具使用。

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
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

GitHub Actions 的 `iOS 日常验证与构建` 会在 push/PR 到 `main` 或手动触发时依次执行 SwiftLint、单元测试和 unsigned Archive，并上传未签名 IPA。

生成的 `.xcodeproj`、`build/` 和 `build-artifacts/` 不提交。

## 开发约定

- 新页面状态优先放到现有 Store 的明确职责中，避免继续扩大 `ChatStore`。
- 网络请求通过 `HTTPClient`，Socket payload 通过 `SocketPayloadEncoder`。
- 新协议先改两端契约，再改调用点，并补契约测试。
- 新数据库字段在 `server/src/db/index.ts` 追加版本化变更。
- Bug 修复优先补最小复现测试；无法自动化的真机问题写入 `PROJECT_STATUS.md`。
- 日志不得包含 token、密码、API key、完整私聊内容或数据库连接串。

## 提交前检查

```powershell
git status --short
git diff --check
cd server
npm test
npm run build
```

iOS 改动还需确认对应 GitHub Actions 通过。
