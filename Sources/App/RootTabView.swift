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

struct RootTabView: View {
    @State private var tab: MainTab = .chat
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var timelineStore: ChatTimelineStore
    // 订阅主题变化：主题色一改，标签栏和全部子页立即重绘
    @EnvironmentObject private var theme: ThemeManager
    @State private var lastSeenEffectMessageId: String?
    @State private var lastSeenNoteId: String?
    @State private var activePresentation: InteractionPresentation?
    @State private var effectQueue: [InteractionPresentation] = []
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
                    .tag(MainTab.chat)
                MomentsView()
                    .tabItem { Label(MainTab.records.rawValue, systemImage: MainTab.records.icon) }
                    .tag(MainTab.records)
                DajuView()
                    .tabItem { Label(MainTab.pet.rawValue, systemImage: MainTab.pet.icon) }
                    .tag(MainTab.pet)
                PlansView()
                    .tabItem { Label(MainTab.reminders.rawValue, systemImage: MainTab.reminders.icon) }
                    .tag(MainTab.reminders)
                AccountView()
                    .tabItem { Label(MainTab.profile.rawValue, systemImage: MainTab.profile.icon) }
                    .tag(MainTab.profile)
            }
            .tabViewStyle(.sidebarAdaptable)

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
            lastSeenEffectMessageId = coupleMessages.last?.id
            handleIncomingNote()
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
    }

    private func handleIncomingInteraction() {
        guard let message = coupleMessages.last else { return }
        guard message.id != lastSeenEffectMessageId else { return }
        lastSeenEffectMessageId = message.id
        guard message.channel == ChatChannel.couple.rawValue,
              message.sender != store.session?.username,
              Date().timeIntervalSince1970 * 1000 - message.ts < 20_000,
              let payload = message.interactionPayload,
              payload.kind != .note else { return }
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
              id != lastSeenNoteId,
              id != dismissedNoteId,
              value["dismissed"] as? Bool != true else { return }
        guard value["from"] as? String != store.session?.username,
              let text = value["text"] as? String else { return }
        lastSeenNoteId = id
        enqueueEffect(InteractionPresentation(
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

    private func enqueueEffect(_ presentation: InteractionPresentation) {
        guard activePresentation?.id != presentation.id,
              !effectQueue.contains(where: { $0.id == presentation.id }) else { return }
        guard activePresentation != nil else {
            DS.Anim.withMotion(DS.Anim.spring) {
                activePresentation = presentation
            }
            return
        }
        effectQueue.append(presentation)
    }

    private func finishActiveEffect() {
        DS.Anim.withMotion(DS.Anim.ease) { activePresentation = nil }
        guard !effectQueue.isEmpty else { return }
        let next = effectQueue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            DS.Anim.withMotion(DS.Anim.spring) {
                activePresentation = next
            }
        }
    }

}

/// 一级 Tab 只出现在五个根页面。由每个 push 目的页直接声明隐藏，避免等到
/// `onAppear` 后再切换造成安全区仍按旧 Tab Bar 高度布局。
extension View {
    func appSubpageChrome() -> some View {
        toolbar(.hidden, for: .tabBar)
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
