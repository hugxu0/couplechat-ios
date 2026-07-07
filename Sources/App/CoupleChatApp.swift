import SwiftUI

@main
struct CoupleChatApp: App {
    @StateObject private var store = ChatStore()
    @StateObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.loggedIn {
                    RootTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(store)
            .environmentObject(theme)
            .preferredColorScheme(theme.appearance.colorScheme)
            .tint(theme.accent.color)
            .onAppear { store.bootstrap() }
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
