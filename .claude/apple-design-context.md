# Apple Design Context

## Product

- **Name**: 悄悄话 (CoupleChat)
- **Description**: 只服务 `xu` 与 `si` 的原生 Apple 平台共同生活应用
- **Category**: Social / Lifestyle
- **Stage**: Active personal product

## Platforms

| Platform | Supported | Min OS | Notes |
|---|---|---|---|
| iOS | Yes | 26.0 | Native iPhone experience |
| iPadOS | Yes | 26.0 | Adaptive portrait, landscape, Split View and Stage Manager |
| macOS / tvOS / watchOS / visionOS | No | — | — |

## Technology

- SwiftUI shells with UIKit chat timeline, composer and media viewer.
- Offline-first SQLite cache, versioned HTTP, Socket.IO and simultaneous multi-device sessions.
- PhotosUI, UserNotifications, Keychain and AVFoundation.

## Design Direction

- Warm, mature shared-life aesthetic with restrained materials.
- Use semantic tokens from `Sources/DesignSystem`; avoid generic full-screen gradients and glass on every surface.
- Support adaptive dark mode, Dynamic Type, VoiceOver, Reduce Motion and non-color status cues.
- iPad layouts respond to available width and support pointer and keyboard interaction.
- Preserve chat reliability, keyboard behavior, scroll anchors and media transitions when changing visual code.

## Product Rules

- No registration, invitation or pairing flow; only the two fixed accounts can authenticate.
- The same account may stay signed in on multiple iPhone/iPad devices.
- Read receipts and online presence are mandatory; recall removes complete message payload and attachments.
- Bark is the push channel. Shared reminders notify both users' active devices; private reminders notify the creator's devices.
- Memory is managed from Settings. Live Photo currently falls back to a static image.
