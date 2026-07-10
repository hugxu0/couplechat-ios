import SwiftUI
import UIKit

struct ChatV2Screen: View {
    let channel: ChatChannel

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var mediaViewerMessageId: String?
    @State private var jumpCommand: ChatV2JumpCommand?
    @State private var isShowingDetail = false
    // UIVisualEffectView 在导航转场的第一帧会先呈现默认材质。先保持透明，
    // 再无动画地启用已确定色调的羽化层，避免一进聊天页闪一帧白雾。
    @State private var hasResolvedTopBackdrop = false

    private var title: String {
        switch channel {
        case .couple: return store.partnerDisplayName(fallback: "聊天")
        case .ai: return "大橘"
        }
    }

    private var subtitle: String {
        switch store.connectionState {
        case .connecting:
            return "连接中"
        case .reconnecting:
            return "正在重连"
        case .failed:
            return store.lastConnectionError ?? "连接失败"
        case .disconnected:
            return "未连接"
        case .connected:
            break
        }
        switch channel {
        case .couple: return store.partnerOnline ? "在线" : "离线"
        case .ai: return store.aiTyping ? "正在输入" : "陪你聊天"
        }
    }

    private var peerAvatar: String {
        if channel == .ai { return "🐱" }
        return store.partner?.avatar ?? AccountPresentation.avatar(for: store.partner?.username ?? "si")
    }

    private var peerAvatarURL: URL? {
        channel == .ai ? nil : store.avatarURL(for: store.partner?.username)
    }

    private var mediaMessages: [ChatMessage] {
        Array(store.mediaMessages(for: channel, includeFiles: false).reversed())
    }

    /// 顶栏和输入栏是两块独立的“表面”：它们应该由实际壁纸采样决定，
    /// 而不是受系统深浅模式或同一段渐变的偶然观感影响。
    private var topSurfaceLuminance: CGFloat {
        if let luminance = theme.customWallpaperLuminance(for: channel, region: .topCenter) {
            return luminance
        }
        return displayedWallpaper == .night ? 0.18 : 0.82
    }

    private var composerSurfaceLuminance: CGFloat {
        if let luminance = theme.customWallpaperLuminance(for: channel, region: .composerCenter) {
            return luminance
        }
        return displayedWallpaper == .night ? 0.18 : 0.82
    }

    private var topChromeTone: ChatSurfaceTone {
        ChatSurfaceTone(luminance: topSurfaceLuminance)
    }

    private var composerChromeTone: ChatSurfaceTone {
        ChatSurfaceTone(luminance: composerSurfaceLuminance)
    }

    private var timelineUsesLightContent: Bool {
        if let luminance = theme.customWallpaperLuminance(for: channel, region: .timelineCenter) {
            return ChatSurfaceTone(luminance: luminance).usesLightContent
        }
        return displayedWallpaper == .night
    }

    private var usesDarkChatSurface: Bool {
        if theme.hasCustomWallpaper(for: channel) {
            let top = theme.customWallpaperLuminance(for: channel, region: .topCenter) ?? 0.5
            let composer = theme.customWallpaperLuminance(for: channel, region: .composerCenter) ?? 0.5
            return (top + composer) / 2 < 0.47
        }
        return displayedWallpaper == .night
    }

    private var topPrimaryColor: Color {
        topChromeTone.primaryTextColor
    }

    private var topSecondaryColor: Color {
        if store.connectionState.isUnavailable { return .red }
        if store.connectionState.isTransient { return .orange }
        return topChromeTone.secondaryTextColor
    }

    private var topShadowColor: Color {
        topChromeTone.usesLightContent ? .black.opacity(0.42) : .white.opacity(0.34)
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let topOverlayInset = safeTop + 58
            let screenSize = UIScreen.main.bounds.size
            let stableWidth = max(proxy.size.width, screenSize.width)
            let stableHeight = max(proxy.size.height, screenSize.height)

            ZStack(alignment: .top) {
                chatBackground
                    .frame(width: stableWidth, height: stableHeight)
                    .position(x: stableWidth / 2, y: stableHeight / 2)
                    .clipped()
                    .ignoresSafeArea(.all)
                    .allowsHitTesting(false)

                ChatUIKitHost(
                    channel: channel,
                    topOverlayInset: topOverlayInset,
                    composerUsesLightContent: composerChromeTone.usesLightContent,
                    dynamicallySamplesComposerTone: theme.hasCustomWallpaper(for: channel),
                    usesDarkChatSurface: usesDarkChatSurface,
                    timelineUsesLightContent: timelineUsesLightContent,
                    jumpCommand: $jumpCommand,
                    onMediaTap: { mediaViewerMessageId = $0 }
                )
                .frame(width: stableWidth, height: stableHeight)
                .position(x: stableWidth / 2, y: stableHeight / 2)
                .ignoresSafeArea(.all)

                topSafeGlass(height: safeTop + 72)
                    .frame(width: proxy.size.width, height: safeTop + 72)
                    .ignoresSafeArea(edges: .top)

                topBar
                    .padding(.top, 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(chatBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .fullScreenCover(isPresented: Binding(
            get: { mediaViewerMessageId != nil },
            set: { if !$0 { mediaViewerMessageId = nil } }
        )) {
            MediaPagerView(messages: mediaMessages, selectedId: $mediaViewerMessageId)
        }
        .onAppear {
            app.pushSubpage()
            // 此时壁纸采样已同步完成；不要给首帧叠加默认浅色材质。
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                hasResolvedTopBackdrop = true
            }
        }
        .onDisappear { app.popSubpage() }
        .background(SwipeBackEnabler())
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(topPrimaryColor)
                    .shadow(color: topShadowColor, radius: 1.5, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(topPrimaryColor)
                    .shadow(color: topShadowColor, radius: 1.5, x: 0, y: 1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(topSecondaryColor)
                    .shadow(color: topShadowColor.opacity(0.8), radius: 1, x: 0, y: 1)
            }
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(minWidth: 156, minHeight: 42)
            .chatTopLiquidGlass(cornerRadius: 21, tone: topChromeTone)

            Spacer(minLength: 0)

            NavigationLink(isActive: $isShowingDetail) {
                ChatDetailSettingsView(
                    channel: channel,
                    partnerName: title,
                    partnerAvatar: peerAvatar,
                    partnerOnline: store.partnerOnline,
                    onJumpToMessage: { message in
                        isShowingDetail = false
                        let command = ChatV2JumpCommand(action: .message(message))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            jumpCommand = command
                        }
                    },
                    onJumpToDate: { date in
                        isShowingDetail = false
                        let command = ChatV2JumpCommand(action: .date(date))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            jumpCommand = command
                        }
                    }
                )
            } label: {
                AvatarBadge(
                    url: peerAvatarURL,
                    fallbackEmoji: peerAvatar,
                    size: 35,
                    background: .clear
                )
                .padding(4.5)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 0)
        .padding(.bottom, 7)
        .contentShape(Rectangle())
        .zIndex(10)
    }

    @ViewBuilder
    private func topSafeGlass(height: CGFloat) -> some View {
        // 暗壁纸不额外铺一层顶端材质，只有胶囊自己维持偏暗的 Liquid Glass；
        // 亮壁纸才需要一层很短的白色羽化，以便黑字稳定可读。
        if hasResolvedTopBackdrop && topChromeTone.usesDarkText {
            TopBackdropBlur(style: .systemUltraThinMaterialLight)
                .mask(
                    LinearGradient(
                        colors: [.white.opacity(0.64), .white.opacity(0.20), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: height)
                .allowsHitTesting(false)
        } else {
            Color.clear
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var chatBackground: some View {
        let wallpaper = displayedWallpaper
        ZStack {
            wallpaper.gradient(dark: colorScheme == .dark)
            if let img = theme.customWallpaperImage(for: channel) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                wallpaper.patternOverlay
            }
        }
    }

    private var displayedWallpaper: WallpaperChoice {
        if colorScheme == .dark && !theme.hasCustomWallpaper(for: channel) {
            return .night
        }
        return theme.wallpaper(for: channel)
    }

}

private extension ChatSurfaceTone {
    /// 以胶囊正后方的中位亮度为准。阈值只在一个地方定义，
    /// 使面板的黑/白材质与所有内部文字永远相反，不会各自漂移。
    var primaryTextColor: Color { usesLightContent ? .white : Color.black.opacity(0.86) }
    var secondaryTextColor: Color { usesLightContent ? Color.white.opacity(0.82) : Color.black.opacity(0.54) }
    var panelTintColor: UIColor { usesLightContent ? .black : .white }
    var panelTintAlpha: CGFloat { usesLightContent ? 0.16 : 0.18 }
    var panelBorderAlpha: CGFloat { usesLightContent ? 0.14 : 0.20 }
    var panelGradientAlpha: CGFloat { usesLightContent ? 0.14 : 0.24 }
}

private extension View {
    func chatTopLiquidGlass(cornerRadius: CGFloat, tone: ChatSurfaceTone) -> some View {
        self
            .background {
                LiquidGlassBackground(
                    cornerRadius: cornerRadius,
                    tintColor: tone.panelTintColor,
                    tintAlpha: tone.panelTintAlpha,
                    borderAlpha: tone.panelBorderAlpha,
                    gradientAlpha: tone.panelGradientAlpha
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct LiquidGlassBackground: UIViewRepresentable {
    let cornerRadius: CGFloat
    var tintColor: UIColor = .white
    var tintAlpha: CGFloat = 0.18
    var borderAlpha: CGFloat = 0.22
    var gradientAlpha: CGFloat = 1

    func makeUIView(context: Context) -> ChatGlassView {
        let view = ChatGlassView(style: .systemUltraThinMaterial, cornerRadius: cornerRadius)
        view.update(cornerRadius: cornerRadius, tintAlpha: tintAlpha, borderAlpha: borderAlpha)
        view.setTintColor(tintColor, alpha: tintAlpha)
        view.setGradientAlpha(gradientAlpha)
        return view
    }

    func updateUIView(_ view: ChatGlassView, context: Context) {
        view.update(cornerRadius: cornerRadius, tintAlpha: tintAlpha, borderAlpha: borderAlpha)
        view.setTintColor(tintColor, alpha: tintAlpha)
        view.setGradientAlpha(gradientAlpha)
    }
}

/// 仅用于顶端背景：UIBlurEffect 会采样其后的真实壁纸，
/// 不带 Liquid Glass 的折射高光，因此不会把浅色场景洗成白雾。
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

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let navigationController = controller.navigationController else { return }
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
            navigationController.interactivePopGestureRecognizer?.delegate = nil
        }
    }
}

struct ChatV2JumpCommand: Identifiable {
    enum Action {
        case message(ChatMessage)
        case date(Date)
    }

    let id = UUID()
    let action: Action
}

private struct ChatUIKitHost: UIViewControllerRepresentable {
    let channel: ChatChannel
    let topOverlayInset: CGFloat
    let composerUsesLightContent: Bool
    let dynamicallySamplesComposerTone: Bool
    let usesDarkChatSurface: Bool
    let timelineUsesLightContent: Bool
    @Binding var jumpCommand: ChatV2JumpCommand?
    let onMediaTap: (String) -> Void

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(
            channel: channel,
            store: store,
            theme: theme,
            composerUsesLightContent: composerUsesLightContent,
            dynamicallySamplesComposerTone: dynamicallySamplesComposerTone,
            usesDarkChatSurface: usesDarkChatSurface,
            timelineUsesLightContent: timelineUsesLightContent,
            onMediaTap: onMediaTap
        )
        controller.setTopOverlayInset(topOverlayInset)
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.updateEnvironment(
            store: store,
            theme: theme,
            topOverlayInset: topOverlayInset,
            composerUsesLightContent: composerUsesLightContent,
            dynamicallySamplesComposerTone: dynamicallySamplesComposerTone,
            usesDarkChatSurface: usesDarkChatSurface,
            timelineUsesLightContent: timelineUsesLightContent,
            onMediaTap: onMediaTap
        )
        if let command = jumpCommand {
            controller.performJump(command)
            DispatchQueue.main.async {
                jumpCommand = nil
            }
        }
    }
}
