import SwiftUI
import UIKit
import UserNotifications

@main
struct CoupleChatApp: App {
    @StateObject private var store = ChatStore()
    @StateObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped = false

    init() {
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
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
            .environmentObject(theme)
            .preferredColorScheme(theme.appearance.colorScheme)
            .tint(theme.accent.color)
            .task {
                guard !bootstrapped else { return }
                store.bootstrap()
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
                case .background, .inactive: store.reportAway(true)
                @unknown default: break
                }
            }
        }
    }
}

private struct LaunchSplashView: View {
    var body: some View {
        ZStack {
            Image("LaunchSplash")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(red: 0.70, green: 0.42, blue: 0.30))
                    .padding(.bottom, 72)
            }
        }
        .background(Color(red: 0.99, green: 0.94, blue: 0.94))
    }
}
