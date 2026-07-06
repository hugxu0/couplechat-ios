import SwiftUI

// 五个主页面 + 自绘底部标签栏（不用系统 TabView 的默认样式，
// 为了完全控制圆角、透明度和选中动画，跟设计系统保持一致）。

enum MainTab: String, CaseIterable {
    case chat = "聊天"
    case records = "记录"
    case pet = "大橘"
    case reminders = "提醒"
    case profile = "我的"

    var icon: String {
        switch self {
        case .chat: return "ellipsis.message.fill"
        case .records: return "book.closed.fill"
        case .pet: return "cat.fill"
        case .reminders: return "bell.fill"
        case .profile: return "person.fill"
        }
    }
}

/// 跨页面共享的 App 状态（比如「正在会话中 → 隐藏底栏」）
final class AppState: ObservableObject {
    @Published var chatOpen = false
}

struct RootTabView: View {
    @State private var tab: MainTab = .chat
    @StateObject private var app = AppState()

    var body: some View {
        ZStack(alignment: .bottom) {
            DS.Palette.bgGradient.ignoresSafeArea()

            Group {
                switch tab {
                case .chat: ChatHomeView()
                case .records: RecordsView()
                case .pet: PetView()
                case .reminders: RemindersView()
                case .profile: ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 会话中隐藏底栏，退出会话时滑回来
            if !app.chatOpen {
                tabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.Anim.spring, value: app.chatOpen)
        .environmentObject(app)
    }

    private var tabBar: some View {
        HStack {
            ForEach(MainTab.allCases, id: \.self) { t in
                Button {
                    // 状态切换必须即时生效，不包进动画事务——
                    // 否则快速连点时切换会被动画排队拖住、感觉「点了没反应」。
                    tab = t
                    Haptics.selection()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon)
                            .font(.system(size: 20))
                            .scaleEffect(tab == t ? 1.08 : 1.0)
                        Text(t.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tab == t ? DS.Palette.accent : DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle()) // 整块区域可点，不只是图标文字
                }
                .buttonStyle(.plain)
                .animation(DS.Anim.springFast, value: tab)
            }
        }
        .padding(.vertical, 8)
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.tabBar, style: .continuous))
        .padding(.horizontal, DS.Spacing.page)
    }
}

/// 触觉反馈统一入口
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
