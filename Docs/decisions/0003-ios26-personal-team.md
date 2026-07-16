# ADR-0003：iOS 26 与免费 Personal Team 侧载

- 状态：Accepted
- 日期：2026-07-16

## 决策

客户端最低系统保持 iOS/iPadOS 26，目标设备为两台 iPhone 17 和一台 iPad。项目暂不进入 TestFlight/App Store，不购买 Apple Developer Program；GitHub 只构建 unsigned IPA，签名在用户本机用免费 Personal Team 完成。

## 影响

- 三台设备刚好占满 Apple 免费设备额度；profile 约 7 天到期，需要定期覆盖安装或刷新。
- CI 不保存 Apple 账号、证书或 UDID，不能实现完全无人值守的免费签名。
- Windows 主路径依赖第三方侧载工具，必须接受其账号安全和兼容性风险；Mac+Xcode 是官方备选。
- 若以后购买开发者会员或需要更多设备，再单独评估 TestFlight，不提前把付费分发配置混入当前流程。

