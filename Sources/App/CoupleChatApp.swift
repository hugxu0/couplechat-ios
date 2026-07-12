import SwiftUI
import UIKit
import UserNotifications

@main
struct CoupleChatApp: App {
#if DEBUG
    private let headerFixture = ChatHeaderVisualFixtureConfiguration.fromProcessArguments()
#endif
    @StateObject private var store = ChatStore()
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var mediaFavorites = MediaFavoriteStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped = false

    init() {
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let headerFixture {
                ChatHeaderVisualFixtureScreen(configuration: headerFixture)
            } else {
                appContent
            }
#else
            appContent
#endif
        }
    }

    private var appContent: some View {
        Group {
            if !bootstrapped {
                LaunchSplashView()
            } else if store.loggedIn {
                if store.requiresPairing {
                    CouplePairingView()
                } else {
                    RootTabView()
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.94, blue: 0.95)
                .ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color.white.opacity(0.72),
                    Color(red: 1.0, green: 0.85, blue: 0.89).opacity(0.68),
                    Color(red: 0.95, green: 0.63, blue: 0.75).opacity(0.46),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            Circle()
                .fill(Color.white.opacity(0.42))
                .frame(width: 330, height: 330)
                .blur(radius: 22)
                .offset(x: -120, y: -260)
            Circle()
                .fill(Color(red: 0.86, green: 0.30, blue: 0.53).opacity(0.16))
                .frame(width: 300, height: 300)
                .blur(radius: 34)
                .offset(x: 150, y: 300)

            VStack(spacing: 0) {
                Spacer(minLength: 96)

                SplashConversationMark(pulse: pulse)
                    .frame(width: 176, height: 146)
                    .scaleEffect(appeared ? 1 : 0.76)
                    .opacity(appeared ? 1 : 0)

                Text("LONG NIGHT TALK")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(4.2)
                    .foregroundStyle(Color(red: 0.56, green: 0.27, blue: 0.38).opacity(0.76))
                    .padding(.top, 30)
                    .opacity(appeared ? 1 : 0)

                Text("悄悄话")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.22, green: 0.12, blue: 0.17))
                    .padding(.top, 10)
                    .opacity(appeared ? 1 : 0)

                Capsule()
                    .fill(Color(red: 0.84, green: 0.39, blue: 0.52).opacity(0.52))
                    .frame(width: 42, height: 2)
                    .padding(.top, 18)
                    .scaleEffect(x: appeared ? 1 : 0.2)

                Text("把想说的话，留给最亲近的人")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.34, green: 0.22, blue: 0.26).opacity(0.68))
                    .padding(.top, 28)
                    .opacity(appeared ? 1 : 0)

                SplashLoadingDots(pulse: pulse)
                    .padding(.top, 38)
                    .opacity(appeared ? 1 : 0)

                Spacer()
            }
        }
        .onAppear {
            if reduceMotion {
                appeared = true
                pulse = true
            } else {
                withAnimation(.spring(response: 0.72, dampingFraction: 0.82)) {
                    appeared = true
                }
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }
}

private struct SplashConversationMark: View {
    let pulse: Bool

    var body: some View {
        ZStack {
            SplashBubble()
                .fill(.white.opacity(0.94))
                .frame(width: 126, height: 86)
                .rotationEffect(.degrees(-8))
                .offset(x: -19, y: -9)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 8)

            SplashBubble()
                .fill(Color(red: 0.33, green: 0.13, blue: 0.26))
                .frame(width: 126, height: 86)
                .rotationEffect(.degrees(7))
                .offset(x: 20, y: 11)
                .shadow(color: Color(red: 0.40, green: 0.12, blue: 0.25).opacity(0.24), radius: 14, y: 8)

            Image(systemName: "heart.fill")
                .font(.system(size: 39, weight: .bold))
                .foregroundStyle(Color(red: 0.98, green: 0.47, blue: 0.64))
                .scaleEffect(pulse ? 1.08 : 0.94)
                .shadow(color: Color(red: 0.92, green: 0.25, blue: 0.48).opacity(0.22), radius: 9)
        }
    }
}

private struct SplashBubble: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let body = rect.insetBy(dx: 5, dy: 5)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: 26, height: 26))
        path.move(to: CGPoint(x: body.maxX - 36, y: body.maxY - 8))
        path.addLine(to: CGPoint(x: body.maxX + 8, y: body.maxY + 24))
        path.addLine(to: CGPoint(x: body.maxX - 62, y: body.maxY - 27))
        path.closeSubpath()
        return path
    }
}

private struct SplashLoadingDots: View {
    let pulse: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(red: 0.75, green: 0.31, blue: 0.45).opacity(0.74))
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulse ? (index == 1 ? 1.35 : 0.88) : 0.88)
                    .animation(
                        .easeInOut(duration: 0.72)
                            .delay(Double(index) * 0.12)
                            .repeatForever(autoreverses: true),
                        value: pulse
                    )
            }
        }
    }
}
