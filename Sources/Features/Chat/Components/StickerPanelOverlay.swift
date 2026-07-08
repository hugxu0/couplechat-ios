import SwiftUI

/// 表情面板覆盖层：覆盖在消息列表底部，不推动布局
struct StickerPanelOverlay: View {
    let isVisible: Bool
    let onEmoji: (String) -> Void
    let onSendSticker: (Sticker) -> Void
    @ObservedObject var stickerStore: StickerStore
    
    private let panelHeight: CGFloat = 300
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            if isVisible {
                StickerEmojiPanel(
                    store: stickerStore,
                    onEmoji: onEmoji,
                    onSendSticker: onSendSticker
                )
                .frame(height: panelHeight)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isVisible)
    }
}

/// 面板背景容器：提供统一的液态玻璃背景
struct PanelBackground<Content: View>: View {
    @ViewBuilder var content: Content
    
    var body: some View {
        content
            .background(.ultraThinMaterial)
    }
}
