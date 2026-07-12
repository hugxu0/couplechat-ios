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

struct ChatHomeStatusChip: View {
    let status: ChatHomeStatusOption
    let selected: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if selected {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }
                Text(status.title)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? status.color : DS.Palette.textPrimary.opacity(0.72))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule().fill(
                    selected
                        ? AnyShapeStyle(status.color.opacity(0.14))
                        : AnyShapeStyle(.white.opacity(0.52))
                )
            )
            .overlay(Capsule().stroke(selected ? status.color.opacity(0.22) : .white.opacity(0.72), lineWidth: 1))
            .shadow(color: selected ? status.color.opacity(0.12) : .clear, radius: 7, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button(action: onEdit) {
                Label("编辑状态", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除状态", systemImage: "trash")
            }
        }
        .accessibilityHint("点按切换状态，长按可编辑或删除")
    }
}

struct ChatHomeActionButton: View {
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
                                colors: [action.background.opacity(0.82), action.background.opacity(0.42)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                                .stroke(.white.opacity(0.5), lineWidth: 1)
                        }
                        .frame(height: 40)
                    Text(sent ? "✓" : action.emoji)
                        .font(.system(size: 22, weight: .bold))
                        .contentTransition(.numericText())
                }
                Text(action.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, DS.Spacing.compact)
                .background(
                    mine ? accent.opacity(0.16) : Color.white.opacity(0.62),
                    in: RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                        .stroke(mine ? accent.opacity(0.12) : .white.opacity(0.56), lineWidth: 1)
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
            background: .white.opacity(0.7))
    }
}
