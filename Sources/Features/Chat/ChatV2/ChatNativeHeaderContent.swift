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

struct ChatNativeHeaderModifier<Destination: View>: ViewModifier {
    let model: ChatHeaderModel
    let avatarURL: URL?
    @Binding var isShowingDetails: Bool
    let onOpenDetails: () -> Void
    let destination: () -> Destination

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button(action: onOpenDetails) {
                        ChatNativeHeaderTitle(model: model)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开聊天设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(isActive: $isShowingDetails) {
                        destination()
                    } label: {
                        ChatNativeHeaderAvatar(model: model, avatarURL: avatarURL)
                    }
                }
            }
            .toolbarBackground(.automatic, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func chatNativeHeader<Destination: View>(
        model: ChatHeaderModel,
        avatarURL: URL?,
        isShowingDetails: Binding<Bool>,
        onOpenDetails: @escaping () -> Void,
        destination: @escaping () -> Destination
    ) -> some View {
        modifier(ChatNativeHeaderModifier(
            model: model,
            avatarURL: avatarURL,
            isShowingDetails: isShowingDetails,
            onOpenDetails: onOpenDetails,
            destination: destination))
    }
}
