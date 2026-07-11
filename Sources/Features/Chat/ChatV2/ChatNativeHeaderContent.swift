import SwiftUI

struct ChatNativeHeaderTitle: View {
    let model: ChatHeaderModel

    var body: some View {
        VStack(spacing: 1) {
            Text(model.title)
                .font(.headline)
            Text(model.subtitle)
                .font(.caption2)
                .foregroundStyle(statusColor)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch model.connection {
        case .failed: return .red
        case .connecting, .aiComposing: return .orange
        case .online: return .secondary
        }
    }
}

struct ChatNativeHeaderAvatar: View {
    let model: ChatHeaderModel
    let avatarURL: URL?

    var body: some View {
        AvatarBadge(
            url: avatarURL,
            fallbackEmoji: model.avatar,
            size: 34,
            background: .clear)
            .accessibilityLabel("打开聊天设置")
    }
}
