import SwiftUI

// 五个主页面使用系统自适应 Tab：iPhone 为底部标签栏，
// iPad 根据可用宽度转为侧栏，保留系统多任务、键盘与无障碍行为。

enum MainTab: String, CaseIterable {
    case chat = "聊天"
    case records = "时光"
    case pet = "大橘"
    case reminders = "计划"
    case profile = "我的"

    var icon: String {
        switch self {
        case .chat: return "ellipsis.message.fill"
        case .records: return "clock.arrow.circlepath"
        case .pet: return AccountPresentation.dajuIconName
        case .reminders: return "calendar"
        case .profile: return "person.fill"
        }
    }
}

@MainActor
final class AppChromeState: ObservableObject {
    @Published private(set) var hidesTabBar = false

    private var activeSubpages: Set<UUID> = []
    private var pendingLeaves: [UUID: Task<Void, Never>] = [:]

    func enterSubpage(_ id: UUID) {
        pendingLeaves.removeValue(forKey: id)?.cancel()
        guard activeSubpages.insert(id).inserted else { return }
        hidesTabBar = true
    }

    func leaveSubpage(_ id: UUID) {
        pendingLeaves.removeValue(forKey: id)?.cancel()
        pendingLeaves[id] = Task { @MainActor [weak self] in
            // Push 到下一层时，旧页面的 disappear 和新页面的 appear 可能分属
            // 相邻两个更新周期；让一帧可以避免底栏在两层子页面之间闪现。
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingLeaves[id] = nil
            guard self.activeSubpages.remove(id) != nil else { return }
            self.hidesTabBar = !self.activeSubpages.isEmpty
        }
    }
}

struct RootTabView: View {
    @State private var tab: MainTab = .chat
    @StateObject private var chrome = AppChromeState()
    @StateObject private var badges = AppBadgeState.shared
    @StateObject private var deepLinks = AppDeepLinkRouter.shared
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var timelineStore: ChatTimelineStore
    // 订阅主题变化：主题色一改，标签栏和全部子页立即重绘
    @EnvironmentObject private var theme: ThemeManager
    @State private var lastSeenNoteId: String?
    @State private var activePresentation: InteractionPresentation?
    @AppStorage("screen_note.dismissed_id") private var dismissedNoteId = ""

    private var screenNoteId: String? {
        store.sharedValue("screen_note")?["id"] as? String
    }

    var body: some View {
        ZStack {
            AppPageBackground()
            TabView(selection: $tab) {
                ChatHomeView()
                    .tabItem { Label(MainTab.chat.rawValue, systemImage: MainTab.chat.icon) }
                    .badge(unreadChatCount)
                    .tag(MainTab.chat)
                MomentsView()
                    .tabItem { Label(MainTab.records.rawValue, systemImage: MainTab.records.icon) }
                    .badge(recommendationBadge)
                    .tag(MainTab.records)
                DajuView()
                    .tabItem { Label(MainTab.pet.rawValue, systemImage: MainTab.pet.icon) }
                    .tag(MainTab.pet)
                PlansView()
                    .tabItem { Label(MainTab.reminders.rawValue, systemImage: MainTab.reminders.icon) }
                    .badge(badges.reminderCount)
                    .tag(MainTab.reminders)
                AccountView()
                    .tabItem { Label(MainTab.profile.rawValue, systemImage: MainTab.profile.icon) }
                    .tag(MainTab.profile)
            }
            .tabViewStyle(.sidebarAdaptable)
            .background(AppTabBarVisibilityController(isHidden: chrome.hidesTabBar))

            if let presentation = activePresentation {
                IncomingInteractionOverlay(
                    payload: presentation.payload,
                    senderName: presentation.senderName,
                    onDismiss: {
                        dismissActivePresentation(presentation)
                    },
                    duration: presentation.duration
                )
                .allowsHitTesting(presentation.payload.kind == .note)
                .zIndex(10)
            }
        }
        .onChange(of: tab) { Haptics.selection() }
        .onAppear {
            presentNextInteractionIfPossible()
            handleIncomingNote()
            handleDeepLink(deepLinks.destination)
        }
        .onChange(of: store.interactionPresentationQueue.first?.id) {
            presentNextInteractionIfPossible()
        }
        .onChange(of: screenNoteId) {
            handleIncomingNote()
        }
        .task(id: store.session?.token) {
            guard let token = store.session?.token else {
                badges.reset()
                return
            }
            await badges.refreshReminders(token: token)
            await badges.refreshRecommendations(token: token)
        }
        .onReceive(NotificationCenter.default.publisher(for: PersonalItemsRepository.changedNotification)) { _ in
            guard let token = store.session?.token else { return }
            Task { await badges.refreshReminders(token: token) }
        }
        .onReceive(NotificationCenter.default.publisher(for: RecommendationRepository.changedNotification)) { _ in
            guard let token = store.session?.token else { return }
            Task { await badges.refreshRecommendations(token: token) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
            guard note.persistentSyncIncludes(["recommendation", "recommendation_state"]),
                  let token = store.session?.token else { return }
            Task { await badges.refreshRecommendations(token: token) }
        }
        .onChange(of: deepLinks.destination) { _, destination in
            handleDeepLink(destination)
        }
        .environmentObject(chrome)
    }

    private var coupleMessages: [ChatMessage] {
        timelineStore.messages(for: .couple)
    }

    private func handleDeepLink(_ destination: AppDeepLink?) {
        guard let destination else { return }
        let notification: Notification.Name
        switch destination {
        case .coupleChat:
            tab = .chat
            notification = .openCoupleChatDeepLink
        case .dajuChat:
            tab = .pet
            notification = .openDajuChatDeepLink
        case .reminders:
            tab = .reminders
            notification = .openRemindersDeepLink
        }
        deepLinks.consume()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    private var unreadChatCount: Int {
        guard let username = store.session?.username else { return 0 }
        // “聊天”Tab 只代表两个人的公共聊天。大橘私聊属于“大橘”Tab，
        // 不能把积累的 AI 消息算进这里，否则刚读完双人聊天仍会残留红点。
        let channel = ChatChannel.couple
        let readAt = timelineStore.readStates[channel.rawValue]?[username] ?? 0
        return timelineStore.messages(for: channel).filter { message in
            message.sender != username
                && message.kind != "system"
                && !message.pending
                && message.ts > readAt
        }
        .count
    }

    private var recommendationBadge: Text? {
        badges.hasUnreadRecommendation ? Text("•") : nil
    }

    private func handleIncomingNote() {
        guard let value = store.sharedValue("screen_note"),
              let id = value["id"] as? String,
              id != lastSeenNoteId,
              id != dismissedNoteId,
              value["dismissed"] as? Bool != true else { return }
        guard value["from"] as? String != store.session?.username,
              let text = value["text"] as? String else { return }
        lastSeenNoteId = id
        store.queueInteractionPresentation(InteractionPresentation(
            payload: InteractionPayload(id: id, kind: .note, text: text),
            senderName: value["fromName"] as? String ?? "TA",
            duration: 2.8))
    }

    private func dismissActivePresentation(_ presentation: InteractionPresentation) {
        if presentation.payload.kind == .note {
            dismissedNoteId = presentation.payload.id
            store.dismissScreenNote(id: presentation.payload.id)
        }
        finishActiveEffect()
    }

    private func finishActiveEffect() {
        DS.Anim.withMotion(DS.Anim.ease) { activePresentation = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            presentNextInteractionIfPossible()
        }
    }

    private func presentNextInteractionIfPossible() {
        guard activePresentation == nil,
              let next = store.takeNextInteractionPresentation() else { return }
        DS.Anim.withMotion(DS.Anim.spring) {
            activePresentation = next
        }
    }

}

private struct AppTabBarVisibilityController: UIViewControllerRepresentable {
    let isHidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> HostController {
        let controller = HostController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.update(isHidden: isHidden, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: HostController, context: Context) {
        controller.update(isHidden: isHidden, animated: !reduceMotion)
    }

    final class HostController: UIViewController {
        private var desiredHidden = false
        private var shouldAnimate = true
        private var lastAppliedHidden: Bool?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyIfPossible()
        }

        func update(isHidden: Bool, animated: Bool) {
            desiredHidden = isHidden
            shouldAnimate = animated
            applyIfPossible()
        }

        private func applyIfPossible() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let tabBarController = self.resolveTabBarController() else { return }
                let changed = tabBarController.isTabBarHidden != self.desiredHidden
                guard changed || self.lastAppliedHidden == nil else { return }

                let animated = self.lastAppliedHidden != nil && self.shouldAnimate
                if changed {
                    tabBarController.setTabBarHidden(self.desiredHidden, animated: animated)
                }
                self.lastAppliedHidden = self.desiredHidden
            }
        }

        private func resolveTabBarController() -> UITabBarController? {
            if let tabBarController { return tabBarController }

            var ancestor = parent
            while let controller = ancestor {
                if let tabBarController = controller as? UITabBarController {
                    return tabBarController
                }
                ancestor = controller.parent
            }

            guard let root = view.window?.rootViewController else { return nil }
            return findTabBarController(in: root)
        }

        private func findTabBarController(in controller: UIViewController) -> UITabBarController? {
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            for child in controller.children {
                if let tabBarController = findTabBarController(in: child) {
                    return tabBarController
                }
            }
            return nil
        }
    }
}

private struct AppSubpageChromeModifier: ViewModifier {
    @EnvironmentObject private var chrome: AppChromeState
    @State private var registrationID = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { chrome.enterSubpage(registrationID) }
            .onDisappear { chrome.leaveSubpage(registrationID) }
    }
}

/// 一级 Tab 只出现在五个根页面。子页面通过身份注册统一驱动原生 Tab Bar，
/// 让显隐和安全区一起使用系统动画更新。
extension View {
    func appSubpageChrome() -> some View {
        modifier(AppSubpageChromeModifier())
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
