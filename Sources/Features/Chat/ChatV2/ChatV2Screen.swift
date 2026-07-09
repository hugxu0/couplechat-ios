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

    private var title: String {
        switch channel {
        case .couple: return store.partnerDisplayName(fallback: "聊天")
        case .ai: return "大橘"
        }
    }

    private var subtitle: String {
        if !store.connected {
            return store.lastConnectionError ?? "未连接"
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
        if let luminance = theme.customWallpaperLuminance(for: channel, region: .top) {
            return luminance
        }
        return displayedWallpaper == .night ? 0.18 : 0.82
    }

    private var usesNightTopChrome: Bool {
        // 低于此值时，黑色玻璃与白色内容的对比度比浅色玻璃稳定。
        topSurfaceLuminance < 0.47
    }

    private var topBarUsesDarkText: Bool {
        !usesNightTopChrome
    }

    private var composerUsesDarkText: Bool {
        if let luminance = theme.customWallpaperLuminance(for: channel, region: .bottom) {
            return luminance > 0.50
        }
        return displayedWallpaper != .night
    }

    private var topPrimaryColor: Color {
        topBarUsesDarkText ? Color.black.opacity(0.86) : .white
    }

    private var topSecondaryColor: Color {
        if !store.connected { return .red }
        return topBarUsesDarkText ? Color.black.opacity(0.54) : Color.white.opacity(0.82)
    }

    private var topShadowColor: Color {
        topBarUsesDarkText ? .white.opacity(0.40) : .black.opacity(0.42)
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
                    composerUsesLightContent: !composerUsesDarkText,
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
                    .chatTopLiquidGlass(cornerRadius: 22, textIsDark: topBarUsesDarkText)
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
            .chatTopLiquidGlass(cornerRadius: 21, textIsDark: topBarUsesDarkText)

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
                    background: .white.opacity(0.10)
                )
                .padding(4.5)
                    .frame(width: 44, height: 44)
                    .chatTopLiquidGlass(cornerRadius: 22, textIsDark: topBarUsesDarkText)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 0)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private func topSafeGlass(height: CGFloat) -> some View {
        Group {
            if usesNightTopChrome {
                // 深色顶端：沿用已验证正常的夜间黑玻璃。
                ZStack {
                    LiquidGlassBackground(
                        cornerRadius: 0,
                        tintColor: .black,
                        tintAlpha: 0.065,
                        borderAlpha: 0,
                        gradientAlpha: 0.14
                    )
                    .mask(
                        LinearGradient(
                            colors: [.black.opacity(0.92), .black.opacity(0.58), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LinearGradient(
                        colors: [.black.opacity(0.10), .black.opacity(0.035), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            } else {
                // 浅色顶端不铺全宽 material；原生材质的高光会叠成用户看到的白雾。
                // 只保留一层极轻的暗色阴影，既让黑色状态栏清楚，又不改变壁纸颜色。
                LinearGradient(
                    colors: [
                        .black.opacity(0.035),
                        .black.opacity(0.010),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
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

private extension View {
    func chatTopLiquidGlass(cornerRadius: CGFloat, textIsDark: Bool) -> some View {
        self
            .background {
                ZStack {
                    LiquidGlassBackground(
                        cornerRadius: cornerRadius,
                        tintColor: textIsDark ? .white : .black,
                        tintAlpha: textIsDark ? 0.14 : 0.34,
                        borderAlpha: textIsDark ? 0.18 : 0.20,
                        gradientAlpha: textIsDark ? 0.22 : 0.30
                    )
                    if !textIsDark {
                        Color.black.opacity(0.12)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke((textIsDark ? Color.white.opacity(0.28) : Color.white.opacity(0.18)), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(textIsDark ? 0.08 : 0.18), radius: 12, x: 0, y: 6)
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

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ChatNavigationChromeController {
        ChatNavigationChromeController()
    }

    func updateUIViewController(_ controller: ChatNavigationChromeController, context: Context) {
        DispatchQueue.main.async {
            controller.applyChatNavigationChrome()
        }
    }
}

/// 聊天画面自行绘制顶端渐变，不能再叠加 App 全局 UINavigationBar 的默认模糊。
/// 仅在此页面透明化导航栏；离开聊天时立即恢复，避免影响聊天详情和其他普通列表页。
private final class ChatNavigationChromeController: UIViewController {
    private weak var observedNavigationController: UINavigationController?
    private var savedStandardAppearance: UINavigationBarAppearance?
    private var savedScrollEdgeAppearance: UINavigationBarAppearance?
    private var savedCompactAppearance: UINavigationBarAppearance?
    private var savedCompactScrollEdgeAppearance: UINavigationBarAppearance?
    private var savedNavigationBarHidden = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyChatNavigationChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreNavigationChrome()
    }

    func applyChatNavigationChrome() {
        guard let navigationController else { return }
        if observedNavigationController !== navigationController {
            restoreNavigationChrome()
            observedNavigationController = navigationController
            let navigationBar = navigationController.navigationBar
            savedStandardAppearance = navigationBar.standardAppearance.copy() as? UINavigationBarAppearance
            savedScrollEdgeAppearance = navigationBar.scrollEdgeAppearance?.copy() as? UINavigationBarAppearance
            savedCompactAppearance = navigationBar.compactAppearance?.copy() as? UINavigationBarAppearance
            savedCompactScrollEdgeAppearance = navigationBar.compactScrollEdgeAppearance?.copy() as? UINavigationBarAppearance
            savedNavigationBarHidden = navigationController.isNavigationBarHidden
        }

        let transparent = UINavigationBarAppearance()
        transparent.configureWithTransparentBackground()
        transparent.backgroundColor = .clear
        transparent.shadowColor = .clear
        let navigationBar = navigationController.navigationBar
        navigationBar.standardAppearance = transparent
        navigationBar.scrollEdgeAppearance = transparent
        navigationBar.compactAppearance = transparent
        navigationBar.compactScrollEdgeAppearance = transparent
        navigationController.setNavigationBarHidden(true, animated: false)
        navigationController.interactivePopGestureRecognizer?.isEnabled = true
        navigationController.interactivePopGestureRecognizer?.delegate = nil
    }

    private func restoreNavigationChrome() {
        guard let navigationController = observedNavigationController else { return }
        let navigationBar = navigationController.navigationBar
        if let savedStandardAppearance { navigationBar.standardAppearance = savedStandardAppearance }
        navigationBar.scrollEdgeAppearance = savedScrollEdgeAppearance
        navigationBar.compactAppearance = savedCompactAppearance
        navigationBar.compactScrollEdgeAppearance = savedCompactScrollEdgeAppearance
        navigationController.setNavigationBarHidden(savedNavigationBarHidden, animated: false)
        observedNavigationController = nil
        savedStandardAppearance = nil
        savedScrollEdgeAppearance = nil
        savedCompactAppearance = nil
        savedCompactScrollEdgeAppearance = nil
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
