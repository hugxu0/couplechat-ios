# Chat V2 原生 UIKit 架构说明

## 目标

Chat V2 的会话核心必须是纯 UIKit：消息列表、消息 cell、输入栏、键盘跟随、表情面板和附件入口由同一个 `UIViewController` 统一调度。SwiftUI 只允许作为当前 App 迁移期的外层导航桥接，不允许进入聊天滚动列表和输入面板的高频路径。

核心原则：

- 消息列表使用 `UICollectionView` 和原生自定义 cell。
- 聊天核心禁止 `UIHostingConfiguration`、SwiftUI hosting cell、SwiftUI 表情面板。
- 输入栏永远存在；键盘、表情面板、附件选择、录音和媒体预览只是输入状态变化。
- 键盘和面板只改底部 dock 的约束；cell 和页面其他区域不直接猜测键盘高度。
- 新消息类型必须新增原生 cell 或原生 renderer，不能把 SwiftUI View 塞回 cell。

## 当前层级

```text
Features/Chat/
├── ChatView.swift                         SwiftUI 会话入口，迁移期桥接
├── ChatV2/
│   ├── ChatV2Screen.swift                  SwiftUI 顶部栏和 UIKit 宿主
│   ├── ChatViewController.swift            UIKit 会话主控制器
│   ├── ChatComposerView.swift              UIKit 输入栏
│   ├── ChatViewController+MediaPicking.swift
│   └── ChatViewController+Recording.swift
└── UIKit/
    ├── ChatTimelineModels.swift            timeline item、layout key、输入状态
    ├── ChatTimelineCells.swift             时间、系统、消息原生 cell
    └── ChatStickerPanelView.swift          原生表情和贴纸面板
```

## 输入状态

输入区采用互斥状态：

```text
idle
editing
emojiPanel
attachmentPicking
mediaPreview
recording(cancelled: Bool)
```

约束：

- `editing` 出现时关闭 `emojiPanel`。
- `emojiPanel` 出现时收起键盘，但 composer 保持可见。
- 有媒体预览时发送按钮发送媒体队列；没有媒体且文字为空时按钮进入录音手势。
- 录音中不允许切换面板和附件。

## 消息生命周期

```text
send action
-> optimistic message
-> durable outbox persist (same clientId for every retry)
-> upload media if needed
-> message:send
-> ack / message:new replace
-> local database persist
-> outbox row and local media cleanup
-> read receipt update
```

失败只影响对应消息的本地状态。文本和媒体都保存在独立 outbox 表；断网、重启或 ACK 丢失后继续使用原 `clientId` 重放，原始 payload 不进入渲染 cell。

## 验收清单

- `rg "UIHostingConfiguration|MessageBubble|StickerEmojiPanel" Sources/Features/Chat` 不应命中聊天实现代码。
- `rg "SwiftUI" Sources/Features/Chat/UIKit` 不应命中。
- 键盘弹起、落下时输入栏跟随，消息列表不跳动。
- 表情面板弹起时输入栏不消失，消息列表只被面板自然顶起。
- 新消息到达时，用户在底部才自动贴底；用户看历史时不抢滚动。
- 上滑加载更早消息后，当前视口锚点保持稳定。
- 文本、图片、视频、语音、文件、贴纸、引用、撤回、已读、失败重试、搜索跳转继续可用。
