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

    private var topBarUsesDarkText: Bool {
        if let image = theme.customWallpaperImage(for: channel) {
            return Self.topRegionLuminance(of: image) > 0.54
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
            store.ensureLocalMessages(channel)
            store.markRead(channel)
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

            NavigationLink {
                ChatDetailSettingsView(
                    channel: channel,
                    partnerName: title,
                    partnerAvatar: peerAvatar,
                    partnerOnline: store.partnerOnline,
                    onJumpToMessage: { jumpCommand = ChatV2JumpCommand(action: .message($0)) },
                    onJumpToDate: { jumpCommand = ChatV2JumpCommand(action: .date($0)) }
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

    private func topSafeGlass(height: CGFloat) -> some View {
        ZStack {
            LiquidGlassBackground(
                cornerRadius: 0,
                tintColor: topBarUsesDarkText ? .white : .black,
                tintAlpha: topBarUsesDarkText ? 0.035 : 0.065,
                borderAlpha: 0,
                gradientAlpha: topBarUsesDarkText ? 0.10 : 0.14
            )
            // 将系统材质本身也渐隐，避免在标题栏底部留下明显的横向分界线。
            .mask(
                LinearGradient(
                    colors: [.black.opacity(0.92), .black.opacity(0.58), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            LinearGradient(
                colors: [
                    (topBarUsesDarkText ? Color.white : Color.black).opacity(topBarUsesDarkText ? 0.06 : 0.10),
                    (topBarUsesDarkText ? Color.white : Color.black).opacity(topBarUsesDarkText ? 0.018 : 0.035),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
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
            }
            wallpaper.patternOverlay
        }
    }

    private var displayedWallpaper: WallpaperChoice {
        if colorScheme == .dark && !theme.hasCustomWallpaper(for: channel) {
            return .night
        }
        return theme.wallpaper(for: channel)
    }

    private static func topRegionLuminance(of image: UIImage) -> CGFloat {
        guard let cgImage = image.cgImage else { return 0.7 }
        let width = 12
        let height = 12
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0.7 }
        let sourceHeight = CGFloat(cgImage.height)
        let cropRect = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: max(1, sourceHeight * 0.22))
        if let topImage = cgImage.cropping(to: cropRect) {
            context.draw(topImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var total: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = CGFloat(pixels[index]) / 255
            let g = CGFloat(pixels[index + 1]) / 255
            let b = CGFloat(pixels[index + 2]) / 255
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / CGFloat(width * height)
    }
}

private extension View {
    func chatTopLiquidGlass(cornerRadius: CGFloat, textIsDark: Bool) -> some View {
        self
            .background {
                ZStack {
                    LiquidGlassBackground(
                        cornerRadius: cornerRadius + 10,
                        tintColor: textIsDark ? .white : .black,
                        tintAlpha: textIsDark ? 0.025 : 0.045,
                        borderAlpha: 0.03,
                        gradientAlpha: 0.18
                    )
                    .padding(-12)
                    .opacity(0.52)

                    LiquidGlassBackground(
                        cornerRadius: cornerRadius,
                        tintColor: textIsDark ? .white : .black,
                        tintAlpha: textIsDark ? 0.16 : 0.12,
                        borderAlpha: textIsDark ? 0.18 : 0.16,
                        gradientAlpha: textIsDark ? 0.30 : 0.24
                    )
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
    @Binding var jumpCommand: ChatV2JumpCommand?
    let onMediaTap: (String) -> Void

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(
            channel: channel,
            store: store,
            theme: theme,
            onMediaTap: onMediaTap
        )
        controller.setTopOverlayInset(topOverlayInset)
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.updateEnvironment(store: store, theme: theme, topOverlayInset: topOverlayInset, onMediaTap: onMediaTap)
        if let command = jumpCommand {
            controller.performJump(command)
            DispatchQueue.main.async {
                jumpCommand = nil
            }
        }
    }
}
