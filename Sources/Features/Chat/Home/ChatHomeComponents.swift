import SwiftUI

// 聊天首页可复用视觉块：分割线、状态胶囊、快捷动作、最新消息行。

struct ChatHomeSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        DS.Palette.textSecondary.opacity(0.04),
                        DS.Palette.textSecondary.opacity(0.22),
                        DS.Palette.textSecondary.opacity(0.04),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

struct ChatHomeActionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let action: ChatHomeQuickAction
    let sent: Bool
    let disabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 7) {
                Text(sent ? "✓" : action.emoji)
                    .font(.system(size: 30))
                    .contentTransition(.numericText())
                Text(action.title)
                    .font(DS.Typo.micro.weight(.bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 104 : 84)
            .background(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [action.background.opacity(0.32), action.background.opacity(0.16)]
                        : [action.background.opacity(0.86), action.background.opacity(0.50)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .stroke(DS.Palette.hairline, lineWidth: 0.8)
            )
            .shadow(
                color: colorScheme == .dark ? .black.opacity(0.20) : .black.opacity(0.035),
                radius: 8,
                y: 3
            )
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .opacity(disabled && !sent ? 0.62 : 1)
        .accessibilityLabel(action.title)
    }
}

struct ChatHomeLatestRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let message: ChatMessage
    let mine: Bool
    let avatarURL: URL?
    let avatarText: String
    let accent: Color
    let preview: String

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.compact) {
            if !mine {
                avatar
            } else {
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 20 : 54)
            }

            Text(preview)
                .font(DS.Typo.secondary.weight(.bold))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .padding(.horizontal, 16)
                .padding(.vertical, DS.Spacing.compact)
                .background(
                    mine ? accent.opacity(0.16) : DS.Palette.innerSurface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                        .stroke(DS.Palette.hairline, lineWidth: 0.8)
                )

            if mine {
                avatar
            } else {
                Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 20 : 54)
            }
        }
    }

    private var avatar: some View {
        AvatarBadge(
            url: avatarURL,
            fallbackEmoji: avatarText,
            size: 31,
            background: DS.Palette.innerSurface)
    }
}
