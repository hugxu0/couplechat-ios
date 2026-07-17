import SwiftUI

struct ChatNativeHeaderTitle: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: ChatHeaderModel
    let usesLightContent: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(model.title)
                .font(.headline)
                .foregroundStyle(usesLightContent ? Color.white : Color.primary)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(model.subtitle)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.title)，\(model.subtitle)")
    }

    private var statusColor: Color {
        switch model.connection {
        case .failed: return .red
        case .connecting, .aiComposing: return .orange
        case .online: return .green
        case .offline: return .secondary
        }
    }
}

struct ChatNativeHeaderModifier<Destination: View>: ViewModifier {
    let model: ChatHeaderModel
    let usesLightContent: Bool
    @Binding var isShowingDetails: Bool
    let onOpenDetails: () -> Void
    let destination: () -> Destination

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button(action: onOpenDetails) {
                        ChatNativeHeaderTitle(
                            model: model,
                            usesLightContent: usesLightContent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .frame(minWidth: 120)
                            .background(glassTone, in: Capsule())
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
                            .font(.body.weight(.semibold))
                            .foregroundStyle(usesLightContent ? Color.white : Color.primary)
                            .frame(width: 36, height: 36)
                            .background(glassTone, in: Circle())
                            .dsGlassInteractive(in: Circle())
                            .accessibilityLabel("打开聊天设置")
                    }
                    .buttonStyle(.plain)
                }
            }
            .toolbarBackground(.automatic, for: .navigationBar)
            .toolbarColorScheme(usesLightContent ? .dark : .light, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var glassTone: Color {
        usesLightContent ? Color.black.opacity(0.26) : Color.white.opacity(0.18)
    }
}

extension View {
    func chatNativeHeader<Destination: View>(
        model: ChatHeaderModel,
        avatarURL: URL?,
        usesLightContent: Bool,
        isShowingDetails: Binding<Bool>,
        onOpenDetails: @escaping () -> Void,
        destination: @escaping () -> Destination
    ) -> some View {
        modifier(ChatNativeHeaderModifier(
            model: model,
            usesLightContent: usesLightContent,
            isShowingDetails: isShowingDetails,
            onOpenDetails: onOpenDetails,
            destination: destination))
    }
}
