# 项目现状

> 更新：2026-08-23。

## 当前状态

- **生产运行 release `b5e60ec`、schema v37**（2026-08-22）。源站已从 RackNerd
  迁移到小米 10（Ubuntu 24.04 ARM64 chroot，自编译 PostgreSQL 16.13，
  mmap + POSIX 信号量适配无 SYSVIPC 内核）；公网入口不变
  （`https://hoo66.top` → RFCHost → Tailnet → 手机）。RackNerd 侧 CoupleChat
  数据与运行环境已清理；数据权威在手机，42 号看护每日备份到 NAS
  （`/mnt/nas/backups/couplechat`，14 天滚动）。
- 部署、migration 与回滚见 [SERVER.md](SERVER.md)；运维仓库另有完整迁移记录。
- 装机 IPA = `964ae81` 版（`D:\Desktop\CoupleChat-IPA\`）。客户端未变，
  本次迁移对 App 完全透明，无需重新安装。

## 产品边界

只服务 `xu` 与 `si` 两位固定用户，同账号可在两台 iPhone 和一台 iPad 同时登录。
主导航：聊天、时光、大橘、计划、我的。没有注册、邀请码、配对或多空间。

## 技术基线

- 客户端：iOS/iPadOS 26、Swift 5.9、SwiftUI + UIKit；版本 `0.2.0 (16)`；
  Bundle ID `com.hugxu0.couplechat.native`；工程由 `project.yml` 生成。
- 依赖：Socket.IO Client Swift `16.1.1`、GLTFKit2 `0.5.15`。
- 服务端：Node.js 22、Fastify 5、Socket.IO 4、PostgreSQL 16；生产主机为小米 10（ARM64 chroot），发布用 `publish-phone.ps1`。
- 公开基地址 `https://hoo66.top`；Debug 与 Release 都连生产，调试时别批量删改数据。
- unsigned IPA 由 GitHub Actions 构建，自己的电脑用免费 Personal Team 签名，
  约 7 天刷新一次。

## 功能一览

- **聊天**：文字、原图、视频、语音、文件、贴纸、引用、搜索、日期跳转、撤回与
  重新编辑、语音转写、严格已读、快捷互动；SQLite 缓存 + outbox + `clientId`
  幂等 + Sync V2 + 断线补拉，弱网收发有完整恢复路径。
- **时光**：纪念日、聊天统计、多本相册与分组动态、今日推荐（大橘生成 + 互荐）。
- **计划**：共享/私人日历、提醒、备忘、Markdown 预览；到期 Bark 推送
  （shared 通知双方全部设备，personal 只通知创建者）。
- **大橘**：3D 猫与五种宠物互动、AI 公聊/私聊、结构化记忆与控制中心、日记、
  情侣卡牌（抽卡、卡库、稀有度、倒计时效果）。
- **我的**：主题、壁纸、头像、设备管理、Bark、收藏、表情库、存储管理。

## 已知问题与限制
- 源站是手机单点：手机断网/断电即服务下线（Magisk 看护可自动恢复）；NAS 是唯一备份副本，建议定期做异机拷贝。

- Live Photo 按静态图发送；iPad 双栏、照片拖放、完整键盘快捷键未完成。
- 卡牌不发通知、不写聊天消息、不接 Sync/Socket，对方靠进页轮询看到效果。
- 快捷互动只在对方位于聊天详情时立即全屏，否则只保留最后一条补展示。
- 日历事件不自动推送（只有提醒走 Bark）；推荐变化不发 Bark。
- 没配 Bark 就没有任何提醒推送（无 APNs、无本地通知）。
- Memory 无本地离线缓存；大橘日记不读私聊、未进 Sync V2。
- 媒体签名 URL 24h 过期后，本地未缓存的老媒体点开会 404，暂无自动重签兜底。
- 上传无进度条，媒体上传会队头阻塞后面的文字消息。
- 仓库没有单元测试：服务端靠 `npm run check`（生产编译 + 内嵌 PostgreSQL 冒烟），
  iOS 靠 CI 编译 + 真机试用。
- 清空 App 数据后已丢失本地文件的失败媒体无法重传。
- 更多待办与审查结论在本机 `private/review-2026-07-26/`（不入库）。

## 常用检查

```powershell
cd server
npm run check
```

iOS 改动推送后看一次 GitHub Actions；涉及交互、媒体、通知或弱网的改动再在
一台真机上实际试用。
