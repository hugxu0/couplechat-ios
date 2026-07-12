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
    @Environment(\.dismiss) private var dismiss

    let model: ChatHeaderModel
    @Binding var isShowingDetails: Bool
    let onOpenDetails: () -> Void
    let destination: () -> Destination

    func body(content: Content) -> some View {
        content
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    ChatNativeHeaderBar(
                        model: model,
                        isShowingDetails: $isShowingDetails,
                        onBack: { dismiss() },
                        onOpenDetails: onOpenDetails,
                        destination: destination)
                        .padding(.top, proxy.safeAreaInsets.top)
                }
            }
    }
}

private struct ChatNativeHeaderBar<Destination: View>: View {
    let model: ChatHeaderModel
    @Binding var isShowingDetails: Bool
    let onBack: () -> Void
    let onOpenDetails: () -> Void
    let destination: () -> Destination

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .dsGlassInteractive(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Spacer(minLength: 0)

            Button(action: onOpenDetails) {
                ChatNativeHeaderTitle(model: model)
                    .padding(.horizontal, 12)
                    .frame(width: 152, height: 44)
                    .dsGlassInteractive(in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开聊天设置")

            Spacer(minLength: 0)

            NavigationLink(isActive: $isShowingDetails) {
                destination()
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .dsGlassInteractive(in: Circle())
                    .accessibilityLabel("打开聊天设置")
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
        .padding(.horizontal, 8)
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
