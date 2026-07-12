# Apple Design Context

## Product
- **Name**: 悄悄话 (CoupleChat)
- **Description**: 面向两位固定用户的原生 iOS 私密聊天应用，含公聊、AI 私聊、记录、提醒与宠物页。
- **Category**: Social / Lifestyle
- **Stage**: Shipped · redesign / unification in progress

## Platforms
| Platform | Supported | Min OS | Notes |
|----------|-----------|--------|-------|
| iOS      | Yes       | 26.0   | Primary target (iPhone) |
| iPadOS   | Build only | 26.0  | Matrix not fully verified |
| macOS    | No        | —      | |
| tvOS     | No        | —      | |
| watchOS  | No        | —      | |
| visionOS | No        | —      | |

## Technology
- **UI Framework**: Mixed — SwiftUI shells + UIKit chat timeline/composer/media viewer
- **Architecture**: Single-window tab app; offline-first SQLite cache; Socket.IO realtime
- **Apple Technologies**: PhotosUI / Live Photo, UserNotifications, Keychain, AVFoundation

## Design System
- **Base**: Custom design system in `Sources/DesignSystem` (`DS`, `Theme`, semantic components)
- **Brand Colors**: Soft multi-stop pastel gradient background; accent choices 蜜橘/樱粉/雾蓝/薄荷/葡萄
- **Typography**: System SF Pro via SwiftUI text styles / UIKit system fonts
- **Materials**: iOS 26 liquid glass on floating chrome; ultraThinMaterial fallback
- **Dark Mode**: Supported via adaptive palette
- **Dynamic Type**: Partial — target enhanced coverage in redesign

## Accessibility
- **Target Level**: Enhanced (VoiceOver labels, Reduce Motion, contrast-safe text on wallpaper)
- **Key Considerations**: Chat wallpaper light/dark content adaptation; media transitions; tab bar hide/show

## Users
- **Primary Persona**: 两位固定情侣用户（xu / si），日常私密沟通
- **Key Use Cases**: 实时聊天、媒体共享、纪念日/记录、提醒备忘、@大橘 AI
- **Known Challenges**: Unify soft-glass aesthetic without breaking chat keyboard/scroll reliability; reduce facade debt while shipping

## Redesign Preferences (2026-07-13)
- Priorities: visual unification + structure + interaction feel + performance
- Cadence: progressive batches with device validation
- Aesthetic: keep soft glass / warm couple tone (not pure system Settings look)
- Chat: deep visual unification allowed, but message reliability / keyboard / scroll anchors remain protected
