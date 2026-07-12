# Apple Design Context

## Product
- **Name**: 悄悄话 (CoupleChat)
- **Description**: 面向成对伴侣的原生 Apple 平台共同生活应用；当前服务一对用户，V2 支持其他情侣注册、配对与独立空间。
- **Category**: Social / Lifestyle
- **Stage**: Personal V1 shipped · extensible V2 productization in progress

## Platforms
| Platform | Supported | Min OS | Notes |
|----------|-----------|--------|-------|
| iOS      | Yes       | 26.0   | Native iPhone experience |
| iPadOS   | Yes       | 26.0   | Native adaptive layout; portrait, landscape, Split View and Stage Manager |
| macOS    | No        | —      | |
| tvOS     | No        | —      | |
| watchOS  | No        | —      | |
| visionOS | No        | —      | |

## Technology
- **UI Framework**: Mixed — SwiftUI shells + UIKit chat timeline/composer/media viewer
- **Architecture**: Universal adaptive app; offline-first SQLite cache; versioned HTTP + Socket.IO sync; simultaneous multi-device sessions
- **Apple Technologies**: PhotosUI / Live Photo, UserNotifications, Keychain, AVFoundation, Speech

## Design System
- **Base**: Custom design system in `Sources/DesignSystem` (`DS`, `Theme`, semantic components)
- **Brand Direction**: Warm, mature shared-life aesthetic with restrained materials; avoid generic full-screen gradients and glass on every surface
- **Signature Motif**: A paired-orbit timeline connecting memories, plans and the shared pet home
- **Accent Choices**: 蜜橘/樱粉/雾蓝/薄荷/葡萄, applied through semantic tokens
- **Typography**: System SF Pro via SwiftUI text styles / UIKit system fonts
- **Materials**: iOS 26 liquid glass on floating chrome; ultraThinMaterial fallback
- **Dark Mode**: Supported via adaptive palette
- **Dynamic Type**: Required throughout the V2 surfaces

## Accessibility
- **Target Level**: Comprehensive product baseline, including VoiceOver, Dynamic Type, Reduce Motion and sufficient contrast
- **Key Considerations**: Chat wallpaper light/dark adaptation; media transitions; keyboard and pointer use on iPad; meaningful focus order; non-color status cues

## Users
- **Primary Persona**: 当前为 xu / si；未来为每个独立配对空间中的两位伴侣
- **Key Use Cases**: 实时聊天、共同相册/那年今日、共享日历与计划、语音转写、Memory 管理、共同养成大橘
- **Known Challenges**: Preserve current couple data while adding tenant boundaries; make every shared mutation converge across phone and tablet; adapt dense collaboration UI without weakening chat reliability

## Redesign Preferences (2026-07-13)
- Priorities: visual unification + structure + interaction feel + performance
- Cadence: progressive batches with device validation
- Aesthetic: keep soft glass / warm couple tone (not pure system Settings look)
- Chat: deep visual unification allowed, but message reliability / keyboard / scroll anchors remain protected

## V2 Product Decisions (2026-07-13)
- The current build remains side-loaded to two devices, but identity and data models must no longer assume exactly two hard-coded usernames.
- A user joins one active couple space through registration and pairing; all shared resources belong to that space, while private AI data and private reminders belong to one member.
- Multiple iPhone and iPad sessions may remain signed in simultaneously. Settings, favorites, stickers, wallpapers and feature data synchronize like messages.
- Read receipts are mandatory and mean that the conversation is visible and the message has actually been presented; online presence is always available.
- Recall removes the complete message payload and attachments from all synchronized views.
- Bark remains the push delivery channel. Shared reminders notify every active device of both members; private reminders notify the creator's active devices only.
- Memory gains a Settings control center for visibility, review, correction, deletion, import/export and AI-use controls.
- V2 feature order: platform/multi-device foundation, Memory center, shared album and On This Day, shared calendar/plans, voice transcription, persistent shared pet.
- Backup stays intentionally lightweight: encrypted database/media snapshots, retention rotation and a verified restore command.
