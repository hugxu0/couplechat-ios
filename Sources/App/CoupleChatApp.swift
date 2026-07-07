import SwiftUI
import UserNotifications

@main
struct CoupleChatApp: App {
    @StateObject private var store = ChatStore()
    @StateObject private var theme = ThemeManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
        configureNavigationBarForStableBlurDuringTransition()
    }

    /// 修复侧滑返回时导航栏毛玻璃变不透明纯色块的 UIKit 渲染 bug。
    ///
    /// 根因：默认 UINavigationBarAppearance（configureWithDefaultBackground）
    /// 含不透明白底 ＋ 模糊。interactive pop 时系统对导航栏做 snapshot，
    /// UIVisualEffectView 在 snapshot 上下文里可能丢失合成上下文，
    /// 导致不透明底色直接暴露。手势结束恢复正常渲染上下文后模糊恢复。
    ///
    /// 修复：改用透明底 ＋ 显式配置 backgroundEffect。
    /// snapshot 阶段透明底不会产生色块；显式的 UIBlurEffect 属性
    /// 在 appearance 快照中比隐式模糊更稳定。
    private func configureNavigationBarForStableBlurDuringTransition() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemMaterial)
        appearance.shadowColor = .clear

        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
        navBar.isTranslucent = true
    }

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
