# iOS agent rules

先遵守根 `AGENTS.md`，再遵守本文件。

- 最低 iOS/iPadOS 26，目标设备为 iPhone 与 iPad；工程定义以根 `project.yml` 为准。
- SwiftUI 负责页面外壳和低频状态，聊天时间线、输入、键盘和高频媒体交互继续由现有 UIKit 路径负责；不要为统一风格进行大爆炸重写。
- SQLite 只通过 `ChatPersistenceProtocol`/actor 访问；UI、MainActor 和控制器不直接执行 SQL，也不同步读取大文件。
- 消息可靠发送保持 `clientId + pending + outbox + 服务端幂等`；任何 cursor 只能在本地事务成功后推进。
- 未知 channel 或 Sync protocolVersion 必须拒绝/隔离，绝不默认映射到 `couple`。
- REST/Socket/Sync 字段变化必须同步修改服务端契约和测试。
- Debug/Release 当前都指向生产是已知风险；未经明确授权，不用开发构建制造或删除生产数据。
- 仓库和 CI 不保存 Apple Account、证书、provisioning profile 或 UDID；workflow 只生成 unsigned IPA。
- 视觉/手势/音视频/通知改动除了自动测试，还要列出需要在三台真机验证的场景。

