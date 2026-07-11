import SwiftUI
import UIKit

struct ChatHeaderChrome<Destination: View>: View {
    let model: ChatHeaderModel
    let avatarURL: URL?
    let tone: ChatSurfaceTone
    @Binding var isShowingDetails: Bool
    let onBack: () -> Void
    let onOpenDetails: () -> Void
    let destination: () -> Destination

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(tone.primaryTextColor)
                    .shadow(color: shadowColor, radius: 1.5, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            Spacer(minLength: 0)

            Button(action: onOpenDetails) {
                VStack(spacing: 2) {
                    Text(model.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tone.primaryTextColor)
                        .shadow(color: shadowColor, radius: 1.5, x: 0, y: 1)
                    Text(model.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(secondaryColor)
                        .shadow(color: shadowColor.opacity(0.8), radius: 1, x: 0, y: 1)
                }
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(minWidth: 156, minHeight: 42)
                .contentShape(Capsule())
                .chatTopLiquidGlass(cornerRadius: 21, tone: tone)
            }
            .buttonStyle(PressableStyle())
            .contextMenu {
                Button(action: onOpenDetails) {
                    Label("聊天设置", systemImage: "slider.horizontal.3")
                }
            }
            .accessibilityLabel("打开聊天设置")

            Spacer(minLength: 0)

            NavigationLink(isActive: $isShowingDetails) {
                destination()
            } label: {
                AvatarBadge(
                    url: avatarURL,
                    fallbackEmoji: model.avatar,
                    size: 35,
                    background: .clear)
                    .padding(4.5)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 7)
        .contentShape(Rectangle())
        .zIndex(10)
    }

    private var shadowColor: Color {
        tone.usesLightContent ? .black.opacity(0.42) : .white.opacity(0.34)
    }

    private var secondaryColor: Color {
        switch model.connection {
        case .failed: return .red
        case .connecting, .aiComposing: return .orange
        case .online: return tone.secondaryTextColor
        }
    }
}

struct ChatHeaderBackdrop: View {
    let height: CGFloat
    let tone: ChatSurfaceTone
    let isResolved: Bool

    var body: some View {
        Group {
            if isResolved && tone.usesDarkText {
                TopBackdropBlur(style: .systemUltraThinMaterialLight)
                    .mask(
                        LinearGradient(
                            colors: [.white.opacity(0.64), .white.opacity(0.20), .clear],
                            startPoint: .top,
                            endPoint: .bottom))
            } else {
                Color.clear
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

private struct TopBackdropBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: style)
    }
}
