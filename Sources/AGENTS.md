# iOS 开发提示

- 最低 iOS/iPadOS 26，工程配置以根 `project.yml` 为准。
- 普通页面沿用 SwiftUI，聊天时间线和高频输入沿用现有 UIKit，不需要为了统一风格整体重写。
- SQLite 通过现有 persistence actor 访问，消息发送沿用 `clientId + pending + outbox + 服务端幂等`。
- REST、Socket 或 Sync 字段变化时同步更新服务端和 `Docs/API.md`。
- Debug 和 Release 当前都连接生产，调试时避免批量写入或删除数据。
- CI 只生成 unsigned IPA；签名信息留在自己的设备上。
- 视觉、音视频、通知或弱网改动在 CI 通过后，用一台相关设备实际试一下。
