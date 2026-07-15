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
    let action: ChatHomeQuickAction
    let sent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: DS.Spacing.tight) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [action.background.opacity(0.34), action.background.opacity(0.16)]
                                    : [action.background.opacity(0.82), action.background.opacity(0.42)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                                .stroke(DS.Palette.textTertiary.opacity(0.15), lineWidth: 1)
                        }
                        .frame(height: 56)
                    Text(sent ? "✓" : action.emoji)
                        .font(.system(size: 29))
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
                Text(action.title)
                    .font(DS.Typo.micro.weight(.bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .disabled(sent)
        .accessibilityLabel(action.title)
    }
}

struct ChatHomeLatestRow: View {
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
                Spacer(minLength: 54)
            }

            Text(preview)
                .font(DS.Typo.secondary.weight(.bold))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, DS.Spacing.compact)
                .background(
                    mine ? accent.opacity(0.16) : DS.Palette.innerSurface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                        .stroke(mine ? accent.opacity(0.12) : DS.Palette.textTertiary.opacity(0.14), lineWidth: 1)
                )

            if mine {
                avatar
            } else {
                Spacer(minLength: 54)
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
