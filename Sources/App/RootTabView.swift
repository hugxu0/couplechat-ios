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

/// 跨页面共享的 App 状态（哪些子页需要隐藏底部标签栏）
final class AppState: ObservableObject {
    /// 子页栈深度：每进入一个需要全屏的子页（聊天、聊天详情、主题、存储…）+1，逐层退出时 -1。
    /// 用计数而不是单个布尔，避免「push 子页时源页 onDisappear 把底栏又放出来」造成的闪烁/残留。
    @Published private var subpageDepth = 0

    /// 只要还在任意子页里就隐藏底部标签栏
    var hidesTabBar: Bool { subpageDepth > 0 }

    func pushSubpage() { subpageDepth += 1 }
    func popSubpage() { subpageDepth = max(0, subpageDepth - 1) }
}

struct RootTabView: View {
    @State private var tab: MainTab = .chat
    @State private var visitedTabs: Set<MainTab> = [.chat]
    @StateObject private var app = AppState()
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var timelineStore: ChatTimelineStore
    // 订阅主题变化：主题色一改，标签栏和全部子页立即重绘
    @EnvironmentObject private var theme: ThemeManager
    @State private var lastSeenEffectMessageId: String?
    @State private var lastSeenNoteId: String?
    @State private var activePresentation: InteractionPresentation?
    @State private var effectQueue: [InteractionPresentation] = []

    private var screenNoteId: String? {
        store.sharedValue("screen_note")?["id"] as? String
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppPageBackground()

            ZStack {
                if visitedTabs.contains(.chat) {
                    ChatHomeView()
                        .opacity(tab == .chat ? 1.0 : 0.0)
                        .disabled(tab != .chat)
                }
                if visitedTabs.contains(.records) {
                    RecordsView()
                        .opacity(tab == .records ? 1.0 : 0.0)
                        .disabled(tab != .records)
                }
                if visitedTabs.contains(.pet) {
                    PetView()
                        .opacity(tab == .pet ? 1.0 : 0.0)
                        .disabled(tab != .pet)
                }
                if visitedTabs.contains(.reminders) {
                    RemindersView()
                        .opacity(tab == .reminders ? 1.0 : 0.0)
                        .disabled(tab != .reminders)
                }
                if visitedTabs.contains(.profile) {
                    ProfileView()
                        .opacity(tab == .profile ? 1.0 : 0.0)
                        .disabled(tab != .profile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 进入子页时隐藏底栏，退出时滑回来
            if !app.hidesTabBar {
                tabBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let presentation = activePresentation {
                IncomingInteractionOverlay(
                    payload: presentation.payload,
                    senderName: presentation.senderName,
                    onDismiss: {
                        finishActiveEffect()
                    },
                    duration: presentation.duration
                )
                .allowsHitTesting(presentation.payload.kind == .note)
                .zIndex(10)
            }
        }
        .animation(DS.Anim.spring, value: app.hidesTabBar)
        .onAppear {
            lastSeenEffectMessageId = coupleMessages.last?.id
            lastSeenNoteId = screenNoteId
        }
        .onChange(of: coupleMessages.last?.id) {
            handleIncomingInteraction()
        }
        .onChange(of: store.localInteractionPresentation?.id) {
            guard let presentation = store.localInteractionPresentation else { return }
            enqueueEffect(presentation)
        }
        .onChange(of: screenNoteId) {
            handleIncomingNote()
        }
        .environmentObject(app)
    }

    private func handleIncomingInteraction() {
        guard let message = coupleMessages.last else { return }
        guard message.id != lastSeenEffectMessageId else { return }
        lastSeenEffectMessageId = message.id
        guard message.channel == ChatChannel.couple.rawValue,
              message.sender != store.session?.username,
              Date().timeIntervalSince1970 * 1000 - message.ts < 20_000,
              let payload = message.interactionPayload else { return }
        enqueueEffect(InteractionPresentation(
            payload: payload,
            senderName: message.senderName.isEmpty ? "TA" : message.senderName,
            duration: payload.kind == .note ? 2.8 : 2.1))
    }

    private var coupleMessages: [ChatMessage] {
        timelineStore.messages(for: .couple)
    }

    private func handleIncomingNote() {
        guard let value = store.sharedValue("screen_note"),
              let id = value["id"] as? String,
              id != lastSeenNoteId else { return }
        lastSeenNoteId = id
        guard value["from"] as? String != store.session?.username,
              let text = value["text"] as? String,
              let ts = (value["ts"] as? NSNumber)?.doubleValue ?? (value["ts"] as? Double),
              Date().timeIntervalSince1970 * 1000 - ts < 300_000 else { return }
        enqueueEffect(InteractionPresentation(
            payload: InteractionPayload(id: "note-\(id)", kind: .note, text: text),
            senderName: value["fromName"] as? String ?? "TA",
            duration: 2.8))
    }

    private func enqueueEffect(_ presentation: InteractionPresentation) {
        guard activePresentation?.id != presentation.id,
              !effectQueue.contains(where: { $0.id == presentation.id }) else { return }
        guard activePresentation != nil else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                activePresentation = presentation
            }
            return
        }
        effectQueue.append(presentation)
    }

    private func finishActiveEffect() {
        withAnimation(.easeOut(duration: 0.2)) { activePresentation = nil }
        guard !effectQueue.isEmpty else { return }
        let next = effectQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                activePresentation = next
            }
        }
    }

    private var tabBar: some View {
        HStack {
            ForEach(MainTab.allCases, id: \.self) { t in
                Button {
                    // 状态切换必须即时生效，不包进动画事务——
                    // 否则快速连点时切换会被动画排队拖住、感觉「点了没反应」。
                    visitedTabs.insert(t)
                    tab = t
                    Haptics.selection()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t == .pet ? AccountPresentation.dajuIconName : t.icon)
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
