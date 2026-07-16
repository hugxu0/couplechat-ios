# 免费账号签名与侧载

## 结论

当前交付分成两个明确阶段：

1. GitHub Actions 在 macOS runner 上生成与 commit 对应的 **unsigned IPA**；
2. 用户在自己的电脑上使用 Apple 免费 Personal Team 凭据重新签名并安装。

iOS 不接受普通自签证书。这里的“免费自签”实际是 Apple 为 Personal Team 签发的 Apple Development 证书和 provisioning profile。

目标设备是两台 iPhone 17 和一台 iPad，均运行最新稳定 iOS/iPadOS 26。Apple 当前免费限制是最多 3 台设备、每台最多 3 个免费开发 App、最多 10 个 App ID，profile 和相关注册 7 天到期；本项目三台设备刚好用满额度，没有第四台余量。

## 当前 Windows 主流程

### 1. 选择精确源码

```powershell
git status --short --branch
$Branch = (git branch --show-current).Trim()
$Sha = (git rev-parse HEAD).Trim()
if (git status --porcelain) { throw "工作树有未提交修改" }
git fetch origin $Branch
if ($LASTEXITCODE -ne 0) { throw "当前分支尚未推送到 origin" }
$RemoteSha = (git rev-parse "origin/$Branch").Trim()
if ($RemoteSha -ne $Sha) { throw "当前 commit 尚未完整推送到 origin/$Branch" }
```

工作树必须干净，当前分支和 commit 必须已经推送到 GitHub；workflow 不能构建只存在于本机的提交。不要用本机旧 `CoupleChat-latest.ipa` 推断它属于当前源码。

### 2. 触发 unsigned IPA

```powershell
gh workflow run build-ipa.yml --ref $Branch
gh run list --workflow build-ipa.yml --commit $Sha --limit 10 `
  --json attempt,databaseId,workflowDatabaseId,headSha,status,conclusion,createdAt
```

`build-ipa.yml` 会先以 reusable workflow 对同一个 commit 执行服务端 test/build、SwiftLint、iPhone 单测和 iPad 编译；全部通过后才归档 unsigned IPA。等待运行 `conclusion=success`，并确认 `headSha` 完整等于 `$Sha`。如果质量门禁失败，不会上传 IPA。

### 3. 按 Run ID 下载和校验

```powershell
.\.github\scripts\download-unsigned-ipa.ps1 -Commit $Sha
```

脚本只接受完整 40 位 commit SHA，并只选择该 SHA 的成功 workflow。需要指定某次重跑时可额外使用 `-RunId <databaseId>`；run 与 commit 不匹配会拒绝。下载后还会验证：

- workflow 文件路径与 workflow database ID，artifact 名称和 `BUILD-METADATA.json` 的 repository、commit、run ID、run attempt；
- IPA 与 metadata 的 SHA-256；
- 直接从 IPA 内实际 `Info.plist` 读取并核对版本、build、Bundle ID 和最低系统，而不是只相信 metadata；
- `Payload/CoupleChat.app`、3D 模型、第三方授权文件存在；
- IPA 不包含 `_CodeSignature`、provisioning profile 或可被 `codesign` 识别的有效签名残留。

artifact 名称包含完整 SHA、run ID 和 attempt，重跑不会与上一次混淆。脚本先在受控 staging 目录完成所有校验，再原子发布到当前用户桌面的 `CoupleChat-IPA`。本项目在当前 Windows 机器上的固定路径是 `D:\Desktop\CoupleChat-IPA`，目录内只保留当前已验证 IPA、`BUILD-METADATA.json` 和 `SHA256SUMS`；下载或校验失败时保留上一份。需要改位置时显式传入 `-OutputDirectory <绝对路径>`，不会再用来源不明的 `CoupleChat-latest.ipa`。

### 4. 本机签名和安装

Windows 可使用 [Sideloadly](https://sideloadly.io/) 等第三方侧载工具，把 unsigned IPA 用免费 Apple Account 重新签名后安装：

1. 这是非 Apple 支持的第三方路径，可能随 iOS 或 Apple 服务变化失效；只从工具官方站和 Apple 官方渠道安装依赖；
2. 首次用 USB 连接设备并在设备上信任电脑；
3. 建议使用专门用于侧载、由本人控制并开启双重认证的 Apple Account；不要使用主要 iCloud 账号，不启用工具的密码/session 保存功能；第三方工具接触账号凭据存在风险，仓库不对其安全性作 Apple 官方保证；
4. 将 IPA 交给工具，三台设备保持同一 Apple Account 和稳定的 Bundle ID；
5. 在设备“设置 → 隐私与安全性”开启开发者模式并按提示重启；必要时在“VPN 与设备管理”信任开发者；
6. 到期前刷新或覆盖安装。不要先删除 App。

首次先在一台设备验证登录、消息、Socket、图片/视频/语音、通知入口和本地数据保留，再安装另外两台。

### 数据连续性

App 使用 Keychain 保存登录、installation ID 和 Bark 配置，SQLite 保存离线消息。刷新时应保持同一签名账号、Bundle ID 和安装身份，并直接覆盖安装。改变 Bundle ID、换 Apple Account 或删除 App 可能失去 Keychain/本地数据库连续性；操作前先确认云端同步和重要媒体备份。

## Mac 官方备选

如果能使用安装了 Xcode 26 的 Mac，最安全的官方路径是：

1. `xcodegen generate`；
2. 在 Xcode Accounts 登录 Apple Account；
3. App target 开启自动签名并选择 Personal Team；
4. 如现有 Bundle ID 无法注册，只修改一次为唯一值，之后保持不变；
5. 逐台连接、信任、开启开发者模式，直接 Build & Run；
6. 每 7 天重新构建安装。

免费 Personal Team 不提供 TestFlight/App Store 分发。Mac 路径的目标是直接安装到已连接设备，不是导出长期有效的分发 IPA。

## 凭据规则

- Apple 密码、2FA、session、证书私钥、`.p12`、`.mobileprovision` 和 UDID 不进入 GitHub Secrets、仓库、日志或 AI 对话；
- GitHub workflow 保持无签名，不上传个人签名产物；
- 用于签名的电脑必须是用户自己的受信设备；
- 第三方工具的兼容性和自动刷新属于其自身声明，iOS 更新后先在一台设备实测。
- 新增 App capability 前先查询 Apple 官方支持矩阵，确认免费 Personal Team 可以签名；不能把付费能力配置到当前目标后再依赖第三方工具绕过。

## 自动化边界

同 SHA 质量门禁、metadata、SHA-256 和强制 commit 下载已在仓库实现，仍需推送后由第一次 GitHub Actions 成功运行完成远程验收。Apple 免费账号登录、2FA、首次信任、开发者模式和本机重新签名不能安全地放进 CI，继续由用户在受信电脑上完成。

## 官方资料

- [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple：在注册设备上分发](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
- [Apple：开启 Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple：支持的 iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)
