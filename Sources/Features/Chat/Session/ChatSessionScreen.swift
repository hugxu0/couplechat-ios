import SwiftUI
import UIKit

struct ChatSessionScreen: View {
    let channel: ChatChannel

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var jumpCommand: ChatSessionJumpCommand?
    @State private var isShowingDetail = false

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
        if store.isAIComposing(in: channel) { return "大橘正在输入" }
        switch channel {
        case .couple:
            if !store.presenceKnown { return "正在获取在线状态" }
            return store.partnerOnline ? "在线" : "离线"
        case .ai: return "陪你聊天"
        }
    }

    private var peerAvatar: String {
        if channel == .ai { return store.avatarText(for: "ai") }
        return store.avatarText(for: store.partner?.username ?? "si")
    }

    private var peerAvatarURL: URL? {
        channel == .ai ? store.avatarURL(for: "ai") : store.avatarURL(for: store.partner?.username)
    }

    private var wallpaperAppearance: WallpaperAppearance {
        WallpaperAppearance(colorScheme: colorScheme)
    }

    /// 顶栏和输入栏是两块独立的“表面”：它们应该由实际壁纸采样决定，
    /// 而不是受系统深浅模式或同一段渐变的偶然观感影响。
    private var composerSurfaceLuminance: CGFloat {
        if let luminance = theme.customWallpaperLuminance(
            for: channel,
            appearance: wallpaperAppearance,
            region: .composerCenter) {
            return luminance
        }
        return displayedWallpaper.fallbackSurfaceLuminance(for: wallpaperAppearance)
    }

    private var composerChromeTone: ChatSurfaceTone {
        ChatSurfaceTone(luminance: composerSurfaceLuminance)
    }

    private var timelineUsesLightContent: Bool {
        if let luminance = theme.customWallpaperLuminance(
            for: channel,
            appearance: wallpaperAppearance,
            region: .timelineCenter) {
            return ChatSurfaceTone(luminance: luminance).usesLightContent
        }
        return ChatSurfaceTone(
            luminance: displayedWallpaper.fallbackSurfaceLuminance(for: wallpaperAppearance)
        ).usesLightContent
    }

    private var usesDarkChatSurface: Bool {
        // 接收气泡只由消息区本身决定，不能再混用顶栏和输入栏的采样值。
        timelineUsesLightContent
    }

    private var headerModel: ChatHeaderModel {
        let connection: ChatHeaderModel.Connection
        if store.isAIComposing(in: channel) {
            connection = .aiComposing
        } else if store.connectionState.isTransient {
            connection = .connecting
        } else if store.connectionState.isUnavailable {
            connection = .failed
        } else if channel == .couple {
            if !store.presenceKnown {
                connection = .connecting
            } else {
                connection = store.partnerOnline ? .online : .offline
            }
        } else {
            connection = .offline
        }
        return ChatHeaderModel(
            title: title,
            subtitle: subtitle,
            avatar: peerAvatar,
            connection: connection,
            isAIComposing: store.isAIComposing(in: channel))
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let topOverlayInset = safeTop + 44
            // 保留原聊天页的完整坐标系与模糊采样，只补回被系统 Tab 容器
            // 截掉的底部高度。宽度仍跟随当前窗口，避免影响 iPad 横向布局。
            let stableWidth = max(proxy.size.width, 1)
            let stableHeight = max(proxy.size.height, UIScreen.main.bounds.height)

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
                    wallpaperAppearance: wallpaperAppearance,
                    dynamicallySamplesComposerTone: theme.hasCustomWallpaper(
                        for: channel,
                        appearance: wallpaperAppearance),
                    usesDarkChatSurface: usesDarkChatSurface,
                    timelineUsesLightContent: timelineUsesLightContent,
                    jumpCommand: $jumpCommand
                )
                .frame(width: stableWidth, height: stableHeight)
                .position(x: stableWidth / 2, y: stableHeight / 2)
                .ignoresSafeArea(.all)

            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(chatBackground.ignoresSafeArea())
        .chatNativeHeader(
            model: headerModel,
            avatarURL: peerAvatarURL,
            isShowingDetails: $isShowingDetail,
            onOpenDetails: {
                Haptics.light()
                isShowingDetail = true
            },
            destination: { chatDetailSettings })
        .appSubpageChrome()
        .background(SwipeBackEnabler())
    }

    private var chatDetailSettings: some View {
        ChatDetailSettingsView(
            channel: channel,
            partnerName: title,
            partnerAvatar: peerAvatar,
            partnerOnline: store.partnerOnline,
            onJumpToMessage: { message in
                isShowingDetail = false
                let command = ChatSessionJumpCommand(action: .message(message))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { jumpCommand = command }
            },
            onJumpToDate: { date in
                isShowingDetail = false
                let command = ChatSessionJumpCommand(action: .date(date))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { jumpCommand = command }
            })
            .appSubpageChrome()
    }

    @ViewBuilder
    private var chatBackground: some View {
        let wallpaper = displayedWallpaper
        ZStack {
            wallpaper.gradient(dark: colorScheme == .dark)
            if let img = theme.customWallpaperImage(for: channel, appearance: wallpaperAppearance) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                wallpaper.patternOverlay
            }
        }
    }

    private var displayedWallpaper: WallpaperChoice {
        theme.wallpaper(for: channel, appearance: wallpaperAppearance)
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

struct ChatSessionJumpCommand: Identifiable {
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
    let wallpaperAppearance: WallpaperAppearance
    let dynamicallySamplesComposerTone: Bool
    let usesDarkChatSurface: Bool
    let timelineUsesLightContent: Bool
    @Binding var jumpCommand: ChatSessionJumpCommand?

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(
            channel: channel,
            store: store,
            theme: theme,
            composerUsesLightContent: composerUsesLightContent,
            wallpaperAppearance: wallpaperAppearance,
            dynamicallySamplesComposerTone: dynamicallySamplesComposerTone,
            usesDarkChatSurface: usesDarkChatSurface,
            timelineUsesLightContent: timelineUsesLightContent
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
            wallpaperAppearance: wallpaperAppearance,
            dynamicallySamplesComposerTone: dynamicallySamplesComposerTone,
            usesDarkChatSurface: usesDarkChatSurface,
            timelineUsesLightContent: timelineUsesLightContent
        )
        if let command = jumpCommand {
            controller.performJump(command)
            DispatchQueue.main.async {
                jumpCommand = nil
            }
        }
    }
}
