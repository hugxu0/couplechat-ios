#if DEBUG
import SwiftUI

struct ChatHeaderVisualFixtureConfiguration: Equatable {
    enum Wallpaper: String { case bright, dark, custom }
    enum Appearance: String { case light, dark }

    let wallpaper: Wallpaper
    let appearance: Appearance
    let connection: ChatHeaderModel.Connection

    static func fromProcessArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard arguments.contains("--chat-header-fixture") else { return nil }
        return Self(
            wallpaper: value(after: "--fixture-wallpaper", in: arguments).flatMap(Wallpaper.init) ?? .bright,
            appearance: value(after: "--fixture-appearance", in: arguments).flatMap(Appearance.init) ?? .light,
            connection: value(after: "--fixture-status", in: arguments)
                .flatMap(ChatHeaderModel.Connection.init) ?? .online)
    }

    private static func value(after key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

struct ChatHeaderVisualFixtureScreen: View {
    let configuration: ChatHeaderVisualFixtureConfiguration
    @State private var isShowingDetails = false

    private var model: ChatHeaderModel {
        switch configuration.connection {
        case .online:
            return ChatHeaderModel(
                title: "小偲", subtitle: "在线", avatar: "偲",
                connection: .online, isAIComposing: false)
        case .connecting:
            return ChatHeaderModel(
                title: "小偲", subtitle: "连接中", avatar: "偲",
                connection: .connecting, isAIComposing: false)
        case .failed:
            return ChatHeaderModel(
                title: "小偲", subtitle: "连接失败", avatar: "偲",
                connection: .failed, isAIComposing: false)
        case .aiComposing:
            return ChatHeaderModel(
                title: "大橘", subtitle: "大橘正在输入", avatar: "橘",
                connection: .aiComposing, isAIComposing: true)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                fixtureWallpaper.ignoresSafeArea()
                fixtureConversation
                ChatHeaderBackdrop(
                    height: proxy.safeAreaInsets.top + 72,
                    tone: headerTone,
                    isResolved: true)
                    .ignoresSafeArea(edges: .top)
                ChatHeaderChrome(
                    model: model,
                    avatarURL: nil,
                    tone: headerTone,
                    isShowingDetails: $isShowingDetails,
                    onBack: {},
                    onOpenDetails: {},
                    destination: { EmptyView() })
            }
        }
        .preferredColorScheme(configuration.appearance == .dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-header-visual-fixture")
    }

    private var fixtureConversation: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 118)
            fixtureBubble("今晚早点回来吗？", mine: false)
            fixtureBubble("好，路上给你带喜欢的。", mine: true)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func fixtureBubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            Text(text)
                .font(.body)
                .foregroundStyle(mine ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    mine ? Color.blue : Color(uiColor: .systemBackground),
                    in: RoundedRectangle(cornerRadius: 18))
            if !mine { Spacer(minLength: 56) }
        }
    }

    @ViewBuilder private var fixtureWallpaper: some View {
        switch configuration.wallpaper {
        case .bright:
            ZStack {
                WallpaperChoice.lavender.gradient(dark: false)
                WallpaperChoice.lavender.patternOverlay
            }
        case .dark:
            ZStack {
                WallpaperChoice.night.gradient(dark: true)
                WallpaperChoice.night.patternOverlay
            }
        case .custom:
            Image("LaunchSplash")
                .resizable()
                .scaledToFill()
                .overlay(alignment: .top) {
                    HStack(spacing: 0) {
                        Color.black.opacity(0.86)
                        Color.white.opacity(0.82)
                    }
                    .frame(height: 180)
                }
        }
    }

    private var headerTone: ChatSurfaceTone {
        switch configuration.wallpaper {
        case .bright: return ChatSurfaceTone(luminance: 0.82)
        case .dark: return ChatSurfaceTone(luminance: 0.18)
        case .custom:
            return ChatSurfaceTone(luminance: configuration.appearance == .dark ? 0.18 : 0.82)
        }
    }
}
#endif
