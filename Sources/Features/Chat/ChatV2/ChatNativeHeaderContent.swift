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

struct ChatNativeHeaderModifier<Destination: View>: ViewModifier {
    let model: ChatHeaderModel
    @Binding var isShowingDetails: Bool
    let onOpenDetails: () -> Void
    let destination: () -> Destination

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button(action: onOpenDetails) {
                        ChatNativeHeaderTitle(model: model)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .frame(minWidth: 120)
                            .dsGlassInteractive(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开聊天设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(isActive: $isShowingDetails) {
                        destination()
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityLabel("打开聊天设置")
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
            isShowingDetails: isShowingDetails,
            onOpenDetails: onOpenDetails,
            destination: destination))
    }
}
