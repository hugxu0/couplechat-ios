#if DEBUG
import SwiftUI

struct ChatNativeHeaderSpikeConfiguration: Equatable {
    let fixture: ChatHeaderVisualFixtureConfiguration

    static func fromProcessArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Self? {
        guard arguments.contains("--chat-header-native-spike") else { return nil }
        var fixtureArguments = arguments
        fixtureArguments.append("--chat-header-fixture")
        guard let fixture = ChatHeaderVisualFixtureConfiguration.fromProcessArguments(fixtureArguments) else {
            return nil
        }
        return Self(fixture: fixture)
    }
}

struct ChatNativeHeaderSpikeScreen: View {
    let configuration: ChatNativeHeaderSpikeConfiguration
    @State private var path = ["chat"]

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(for: String.self) { _ in
                    spikeContent
                }
        }
        .preferredColorScheme(configuration.fixture.appearance == .dark ? .dark : .light)
        .accessibilityIdentifier("chat-native-header-spike")
    }

    private var spikeContent: some View {
        ZStack {
            wallpaper.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer().frame(height: 70)
                fixtureBubble("今晚早点回来吗？", mine: false)
                fixtureBubble("好，路上给你带喜欢的。", mine: true)
                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatNativeHeaderTitle(model: model)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {}) {
                    ChatNativeHeaderAvatar(model: model, avatarURL: nil)
                }
            }
        }
        .toolbarBackground(.automatic, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var model: ChatHeaderModel {
        switch configuration.fixture.connection {
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

    @ViewBuilder private var wallpaper: some View {
        switch configuration.fixture.wallpaper {
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
        }
    }
}
#endif
