# iOS 构建、签名与侧载

## 当前方式

交付分为两个阶段：

1. GitHub Actions 使用 Xcode 26.3 为精确 commit 生成 **unsigned IPA**。
2. 用户在自己的受信电脑上使用免费 Apple Personal Team 重新签名并安装。

目标设备是两台 iPhone 17 和一台 iPad，最低系统为 iOS/iPadOS 26。当前不使用 TestFlight/App Store。免费 Personal Team 的 profile 约 7 天到期，三台设备需要定期覆盖安装或刷新。

## iOS 工程

- 工程定义：根目录 `project.yml`。
- App target：`CoupleChat`。
- Bundle ID：`com.hugxu0.couplechat.native`。
- 版本：`0.2.0 (12)`。
- 依赖：Socket.IO Client Swift `16.1.0`、GLTFKit2 `0.5.15`。
- 必需资源：`Sources/Resources/cute_cat.glb` 和 `ThirdPartyNotices.txt`。
- 仓库不保留 XCTest target。

Mac 无签名编译：

```bash
xcodegen generate
xcodebuild build -project CoupleChat.xcodeproj -scheme CoupleChat \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## 生成 unsigned IPA

### 1. 固定源码

```powershell
git status --short --branch
$Branch = (git branch --show-current).Trim()
$Sha = (git rev-parse HEAD).Trim()
if (git status --porcelain) { throw '工作树有未提交修改' }
git fetch origin $Branch
if ($LASTEXITCODE -ne 0) { throw '当前分支尚未推送' }
$RemoteSha = (git rev-parse "origin/$Branch").Trim()
if ($RemoteSha -ne $Sha) { throw '当前 commit 尚未完整推送' }
```

workflow 不能构建只存在于本机的提交，也不能用本机旧 IPA 推断源码版本。

### 2. 触发 workflow

```powershell
gh workflow run build-ipa.yml --ref $Branch
gh run list --workflow build-ipa.yml --commit $Sha --limit 10 `
  --json attempt,databaseId,workflowDatabaseId,headSha,status,conclusion,createdAt
```

只接受 `headSha` 完整等于 `$Sha` 且 `conclusion=success` 的运行。

### 3. 下载和校验

```powershell
.\.github\scripts\download-unsigned-ipa.ps1 -Commit $Sha
```

需要指定重跑时增加 `-RunId <databaseId>`。脚本校验：

- workflow、repository、完整 commit、run ID 和 attempt；
- artifact 名称和 `BUILD-METADATA.json`；
- IPA、metadata 与 `SHA256SUMS`；
- IPA 实际 `Info.plist` 中的版本、build、Bundle ID 和最低系统；
- App、3D 模型和第三方授权文件；
- 不存在 `_CodeSignature`、provisioning profile 或有效签名残留。

校验在 staging 目录完成后才原子发布到指定输出目录；失败时保留上一份已验证结果。不要使用来源不明的 `CoupleChat-latest.ipa`。

## Windows 侧载

Windows 可以使用 Sideloadly 等第三方工具重新签名，但这不是 Apple 官方路径，可能随 iOS 或 Apple 服务变化：

1. 只从工具官方渠道安装。
2. 首次用 USB 连接并信任电脑。
3. 使用本人控制、开启双重认证且专用于侧载的 Apple Account；不要保存密码或 session。
4. 三台设备保持同一账号和稳定 Bundle ID。
5. 在设备开启开发者模式，必要时信任开发者。
6. 到期前覆盖安装；不要先删除 App。

首次只安装一台，验证登录、消息、Socket、图片/视频/语音、通知入口和本地数据，再安装其余设备。

## Mac 官方路径

有 Xcode 26 Mac 时优先使用官方 Build & Run：

1. `xcodegen generate`。
2. 在 Xcode Accounts 登录 Apple Account。
3. App target 开启自动签名并选择 Personal Team。
4. Bundle ID 一旦确定后保持不变。
5. 逐台连接、信任、开启开发者模式并 Build & Run。
6. 每 7 天重新构建覆盖安装。

免费 Personal Team 不能提供 TestFlight/App Store 分发，也不导出长期有效的分发 IPA。

## 数据连续性

Keychain 保存 session、installation ID 和 Bark key；SQLite 保存离线消息。刷新时保持同一 Apple Account、Bundle ID 和安装身份，并直接覆盖安装。

改变 Bundle ID、换签名账号或删除 App 可能破坏 Keychain/SQLite 连续性。操作前先确认云端同步完成和重要媒体已有备份。

## 凭据与自动化边界

- Apple 密码、2FA、session、证书私钥、`.p12`、`.mobileprovision` 和 UDID 不进入 GitHub Secrets、Git、日志或 AI 对话。
- GitHub workflow 永远保持 unsigned，不上传个人签名产物。
- 签名电脑必须是用户自己的受信设备。
- 免费账号登录、2FA、首次信任、开发者模式和本机签名不能放入 CI。
- 新增 capability 前先确认免费 Personal Team 支持，不能依赖第三方工具绕过 Apple 限制。

## 官方资料

- [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple：在注册设备上分发](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
- [Apple：开启 Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple：iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)
