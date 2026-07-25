# iOS 构建、签名与安装

项目使用 GitHub Actions 生成 unsigned IPA，再由自己的电脑使用免费 Apple Personal Team 签名安装。当前最低系统为 iOS/iPadOS 26，免费签名通常约 7 天需要刷新。

## 工程信息

- 工程配置：根目录 `project.yml`
- Target：`CoupleChat`
- Bundle ID：`com.hugxu0.couplechat.native`
- 依赖：Socket.IO Client Swift `16.1.1`、GLTFKit2 `0.5.15`
- 必需资源：`Sources/Resources/cute_cat.glb`、`ThirdPartyNotices.txt`

Mac 无签名编译：

```bash
xcodegen generate
xcodebuild build -project CoupleChat.xcodeproj -scheme CoupleChat \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

## 生成 unsigned IPA

先提交并推送当前分支：

```powershell
$Branch = (git branch --show-current).Trim()
$Sha = (git rev-parse HEAD).Trim()
git push origin $Branch
```

触发构建：

```powershell
gh workflow run build-ipa.yml --ref $Branch
gh run list --workflow build-ipa.yml --commit $Sha --limit 5
```

构建成功后下载：

```powershell
.\.github\scripts\download-unsigned-ipa.ps1 -Commit $Sha
```

下载脚本会自动核对版本、commit、校验和、Bundle ID、必需资源和未签名状态，默认输出到桌面的 `CoupleChat-IPA`。

## 安装

### Windows

可以使用 Sideloadly 等工具为 unsigned IPA 签名：

1. USB 连接并信任设备。
2. 使用自己的 Apple Account 签名。
3. 在设备上开启开发者模式并信任开发者。
4. 到期前直接覆盖安装，尽量不要先删除 App。

首次先装一台设备，确认登录、消息、媒体和通知正常，再装其他设备。

### Mac

有 Mac 时可以直接用 Xcode：

1. 运行 `xcodegen generate`。
2. 在 Xcode 登录 Apple Account。
3. 为 App target 选择 Personal Team 和自动签名。
4. 连接设备后 Build & Run。

## 保留本地数据

Keychain 保存登录状态、installation ID 和 Bark key，SQLite 保存离线消息。刷新签名时保持相同 Bundle ID 和 Apple Account，并覆盖安装，通常可以继续使用原数据。

删除 App、改变 Bundle ID 或换签名账号可能丢失本地缓存。重要内容以服务器同步结果为准。

## 凭据

Apple 密码、2FA、证书私钥和 provisioning profile 留在自己的签名电脑上，不提交 Git。GitHub Actions 只负责 unsigned IPA。
