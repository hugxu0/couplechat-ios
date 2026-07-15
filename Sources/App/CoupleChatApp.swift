import SwiftUI
import UIKit
import UserNotifications

@main
struct CoupleChatApp: App {
    @StateObject private var store = ChatStore()
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var mediaFavorites = MediaFavoriteStore.shared
    @StateObject private var deepLinks = AppDeepLinkRouter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped = false

    init() {
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            appContent
        }
    }

    private var appContent: some View {
        Group {
            if !bootstrapped {
                LaunchSplashView()
            } else if store.loggedIn {
                RootTabView()
            } else {
                LoginView()
            }
        }
        .environmentObject(store)
        .environmentObject(store.messageStore.timelineStore)
        .environmentObject(store.historySync)
        .environmentObject(theme)
        .environmentObject(mediaFavorites)
        .preferredColorScheme(theme.appearance.colorScheme)
        .tint(theme.accent.color)
        .onOpenURL { deepLinks.handle($0) }
        .task(id: store.session?.username) {
            theme.activateAccount(store.session?.username)
        }
        .task {
            guard !bootstrapped else { return }
            await store.bootstrap()
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.24)) {
                    bootstrapped = true
                }
            }
        }
        // 前后台切换：回前台核实连接并补漏；退后台上报 away，
        // 服务端据此把没在看的一方转走系统推送（后续接 Bark）。
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active: store.recoverOnForeground()
            // inactive 会在来电、系统弹窗、图片选择器等短暂打断时出现；
            // 此时把用户标为离开会造成对方在线状态和推送策略抖动。
            case .background: store.reportAway(true)
            case .inactive: break
            @unknown default: break
            }
        }
    }
}

private struct LaunchSplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false

    private var palette: LaunchSplashPalette {
        LaunchSplashPalette(colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(palette.glow)
                .frame(width: 390, height: 390)
                .blur(radius: 56)
                .scaleEffect(pulse && !reduceMotion ? 1.06 : 0.94)
                .opacity(pulse && !reduceMotion ? 0.92 : 0.68)

            VStack(spacing: 0) {
                Spacer()

                Text("LONG NIGHT TALK")
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .tracking(5.5)
                    .foregroundStyle(palette.eyebrow)
                    .padding(.leading, 5.5)
                    .splashReveal(appeared, delay: 0, reduceMotion: reduceMotion)

                Text("漫长悄悄话")
                    .font(.system(size: 38, weight: .semibold, design: .serif))
                    .tracking(2.5)
                    .foregroundStyle(palette.title)
                    .padding(.top, 20)
                    .splashReveal(appeared, delay: 0.06, reduceMotion: reduceMotion)

                Capsule()
                    .fill(palette.rule)
                    .frame(width: 74, height: 1)
                    .padding(.top, 32)
                    .scaleEffect(x: appeared ? 1 : 0.05)
                    .opacity(appeared ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.48).delay(0.12),
                        value: appeared
                    )

                Text("故事自哪一页开始？")
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(palette.secondary)
                    .padding(.top, 38)
                    .splashReveal(appeared, delay: 0.18, reduceMotion: reduceMotion)

                Text("手与手的相握，心与心碰触，\n涌动在喉咙深处，我温暖的火。")
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .tracking(0.7)
                    .multilineTextAlignment(.center)
                    .lineSpacing(13)
                    .foregroundStyle(palette.body)
                    .padding(.top, 30)
                    .splashReveal(appeared, delay: 0.24, reduceMotion: reduceMotion)

                SplashLoadingDots(
                    pulse: pulse,
                    color: palette.accent,
                    reduceMotion: reduceMotion
                )
                    .padding(.top, 42)
                    .splashReveal(appeared, delay: 0.3, reduceMotion: reduceMotion)

                Spacer()
            }
            .padding(.horizontal, 24)
            .offset(y: 36)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
            value: pulse
        )
        .onAppear {
            if reduceMotion {
                appeared = true
                pulse = true
            } else {
                appeared = true
                pulse = true
            }
        }
    }
}

private struct LaunchSplashPalette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let glow: Color
    let eyebrow: Color
    let title: Color
    let rule: Color
    let secondary: Color
    let body: Color
    let accent: Color

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            backgroundTop = Color(red: 0.105, green: 0.073, blue: 0.086)
            backgroundBottom = Color(red: 0.155, green: 0.092, blue: 0.112)
            glow = Color(red: 0.34, green: 0.15, blue: 0.20).opacity(0.52)
            eyebrow = Color(red: 0.82, green: 0.61, blue: 0.56)
            title = Color(red: 0.95, green: 0.89, blue: 0.90)
            rule = Color(red: 0.72, green: 0.47, blue: 0.43).opacity(0.58)
            secondary = Color(red: 0.72, green: 0.62, blue: 0.64)
            body = Color(red: 0.80, green: 0.72, blue: 0.74)
            accent = Color(red: 0.84, green: 0.55, blue: 0.47)
        } else {
            backgroundTop = Color(red: 0.99, green: 0.955, blue: 0.958)
            backgroundBottom = Color(red: 0.982, green: 0.925, blue: 0.915)
            glow = Color(red: 1.0, green: 0.82, blue: 0.73).opacity(0.42)
            eyebrow = Color(red: 0.64, green: 0.43, blue: 0.39)
            title = Color(red: 0.29, green: 0.24, blue: 0.25)
            rule = Color(red: 0.70, green: 0.48, blue: 0.43).opacity(0.42)
            secondary = Color(red: 0.55, green: 0.48, blue: 0.49)
            body = Color(red: 0.43, green: 0.37, blue: 0.38)
            accent = Color(red: 0.78, green: 0.51, blue: 0.40)
        }
    }
}

private struct SplashLoadingDots: View {
    let pulse: Bool
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(0.88 - Double(index) * 0.14))
                    .frame(width: 6, height: 6)
                    .scaleEffect(reduceMotion ? 1 : (pulse ? 1.18 : 0.72))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.58)
                                .delay(Double(index) * 0.14)
                                .repeatForever(autoreverses: true),
                        value: pulse
                    )
            }
        }
    }
}

private struct SplashRevealModifier: ViewModifier {
    let appeared: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 8)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.42).delay(delay),
                value: appeared
            )
    }
}

private extension View {
    func splashReveal(_ appeared: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(
            SplashRevealModifier(
                appeared: appeared,
                delay: delay,
                reduceMotion: reduceMotion
            )
        )
    }
}
