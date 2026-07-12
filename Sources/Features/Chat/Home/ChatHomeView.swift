import SwiftUI

// 聊天首页：把两个人的状态、互动和最近消息收进一张柔软的情侣卡片。
// 视觉块与模型拆到 Home/ 子目录，本文件只负责装配与状态逻辑。

struct ChatHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var timelineStore: ChatTimelineStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var showChat = false
    @State private var sentAction: String?
    @State private var showCustomStatusPrompt = false
    @State private var customStatusText = ""
    @State private var editingStatusID: String?
    @State private var showNotePrompt = false
    @State private var noteText = ""
    @State private var refreshMessage: String?
    @State private var refreshingHome = false
    @State private var pullRefreshArmed = true
    @State private var pullProgress: CGFloat = 0
    @AppStorage("chat_home_statuses_v2") private var statusesJSON = ""
    @AppStorage("chat_home_custom_statuses") private var legacyCustomStatusData = ""

    private var myName: String { store.session?.name ?? "小旭" }
    private var myUsername: String { store.session?.username ?? "xu" }
    private var myAvatar: String { store.avatarText(for: myUsername) }
    private var partnerName: String { store.partnerDisplayName(fallback: "小偲") }
    private var partnerUsername: String { store.partner?.username ?? (myUsername == "xu" ? "si" : "xu") }
    private var partnerAvatar: String {
        store.avatarText(for: partnerUsername)
    }

    private var coupleMessages: [ChatMessage] {
        timelineStore.messages(for: .couple)
    }

    private var statusMap: [String: String] {
        store.sharedValue("chat_statuses") as? [String: String] ?? [:]
    }

    private var storedStatuses: [ChatHomeStoredStatus] {
        if !statusesJSON.isEmpty,
           let data = statusesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ChatHomeStoredStatus].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return migratedDefaultStatuses()
    }

    private var statusOptions: [ChatHomeStatusOption] {
        storedStatuses.enumerated().map { index, stored in
            ChatHomeCatalog.statusOption(stored: stored, index: index)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    shortPullRefreshProbe {
                        Task { @MainActor in
                            await Task.yield()
                            DS.Anim.withMotion(DS.Anim.springFast) {
                                proxy.scrollTo("chat-home-top", anchor: .top)
                            }
                        }
                    }
                    mainPanel
                        .padding(.horizontal, DS.Spacing.page)
                        .padding(.top, 8)
                        .id("chat-home-top")
                    // 卡片外保留一小段真实的滚动缓冲，供下拉刷新和底部标签栏呼吸，
                    // 不再把这块空间塞进「最新消息」里造成一片空白。
                    Color.clear.frame(height: 58)
                }
                .coordinateSpace(name: "chatHomeScroll")
                .scrollIndicators(.hidden)
                .background(AppPageBackground())
                .overlay(alignment: .top) { pullRefreshIndicator }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) { ChatView() }
            .alert(editingStatusID == nil ? "添加状态" : "编辑状态", isPresented: $showCustomStatusPrompt) {
                TextField("比如：想被抱抱", text: $customStatusText)
                Button(editingStatusID == nil ? "添加并使用" : "保存") { saveStatusEditor() }
                if let editingStatusID {
                    Button("删除状态", role: .destructive) { deleteStatus(id: editingStatusID) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(editingStatusID == nil ? "点按状态即可切换，长按已有状态可以编辑。" : "修改后会同步更新当前正在使用的状态。")
            }
            .alert("贴一张小纸条", isPresented: $showNotePrompt) {
                TextField("写一句想贴给 TA 的话", text: $noteText)
                Button("贴上去") { sendNote() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对方会被贴条挡住屏幕，需要手动撕掉。")
            }
            .overlay(alignment: .top) {
                if let refreshMessage {
                    Text(refreshMessage)
                        .font(DS.Typo.sectionLabel)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill((refreshMessage == "刷新成功" ? DS.Palette.green : DS.Palette.red).opacity(0.92))
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        )
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(DS.Anim.ease, value: refreshMessage)
                }
            }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            brandHeader
                .padding(.top, 16)
                .padding(.bottom, 14)

            coupleHeader
                .padding(.bottom, 14)

            ChatHomeSectionDivider()

            statusStrip
                .padding(.top, 10)
                .padding(.bottom, 6)

            ChatHomeSectionDivider()

            actionStrip
                .padding(.top, 8)
                .padding(.bottom, 8)

            ChatHomeSectionDivider()

            latestMessages
                .padding(.top, 10)
                .padding(.bottom, 10)

            enterChatButton
                .padding(.bottom, 10)
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 0, alignment: .top)
        .background(homeCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(color: theme.accent.color.opacity(0.08), radius: 16, y: 6)
    }

    private var brandHeader: some View {
        VStack(spacing: 7) {
            ZStack {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(DS.Typo.cardTitle.weight(.semibold))
                    Text("漫长悄悄话")
                        .font(.system(size: 35, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Image(systemName: "sparkles")
                        .font(DS.Typo.button)
                }
                .foregroundStyle(
                    LinearGradient(
                        colors: [DS.Palette.blue, DS.Palette.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(
                    color: colorScheme == .dark
                        ? theme.accent.color.opacity(0.32)
                        : .white.opacity(0.9),
                    radius: 3
                )

                Image(systemName: "heart.fill")
                    .font(DS.Typo.micro.weight(.bold))
                    .foregroundStyle(DS.Palette.pink.opacity(0.58))
                    .offset(y: -30)
            }

            Text("慢慢说，悄悄听")
                .font(DS.Typo.sectionLabel)
                .foregroundStyle(theme.accent.color.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var homeCardBackground: some View {
        ZStack(alignment: .top) {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.17, green: 0.075, blue: 0.13),
                        Color(red: 0.12, green: 0.045, blue: 0.09),
                        Color(red: 0.075, green: 0.045, blue: 0.115),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [theme.accent.color.opacity(0.18), DS.Palette.pink.opacity(0.08), .clear],
                    center: .top,
                    startRadius: 8,
                    endRadius: 210
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 1, green: 0.975, blue: 0.985),
                        theme.accent.color.opacity(0.12),
                        DS.Palette.pink.opacity(0.09),
                        Color(red: 0.95, green: 0.93, blue: 0.99),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [.white.opacity(0.42), theme.accent.color.opacity(0.06), .clear],
                    center: .top,
                    startRadius: 6,
                    endRadius: 195
                )
            }
            HStack {
                Image(systemName: "sparkles")
                Spacer()
                Image(systemName: "heart.fill")
                    .font(DS.Typo.micro)
            }
            .font(DS.Typo.button)
            .foregroundStyle(theme.accent.color.opacity(0.11))
            .padding(.horizontal, 22)
            .padding(.top, 13)
        }
    }

    private func shortPullRefreshProbe(onRefreshFinished: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.frame(in: .named("chatHomeScroll")).minY) { _, value in
                    if !refreshingHome {
                        pullProgress = min(1, max(0, value / 46))
                    }
                    if value < 8 {
                        pullRefreshArmed = true
                    }
                    guard value > 46, pullRefreshArmed, !refreshingHome else { return }
                    pullRefreshArmed = false
                    refreshingHome = true
                    pullProgress = 1
                    Task {
                        let result = await store.refreshHomeData()
                        await MainActor.run {
                            flashRefreshResult(result)
                            refreshingHome = false
                            pullProgress = 0
                            onRefreshFinished()
                        }
                    }
                }
        }
        .frame(height: 0)
    }

    /// QQ 式下拉指示器：跟随下拉距离渐显/旋转箭头，刷新中换成持续转圈
    private var pullRefreshIndicator: some View {
        Group {
            if refreshingHome {
                ProgressView()
                    .controlSize(.small)
                    .tint(DS.Palette.accent)
            } else {
                Image(systemName: "arrow.down")
                    .font(DS.Typo.sectionLabel)
                    .foregroundStyle(DS.Palette.accent)
                    .rotationEffect(.degrees(pullProgress >= 1 ? 180 : 0))
            }
        }
        .frame(width: 30, height: 30)
        .background(DS.Palette.innerSurface, in: Circle())
        .opacity(refreshingHome ? 1 : pullProgress)
        .scaleEffect(refreshingHome || UIAccessibility.isReduceMotionEnabled ? 1 : 0.6 + 0.4 * pullProgress)
        .padding(.top, DS.Spacing.compact)
        .animation(DS.Anim.motion(DS.Anim.springFast), value: pullProgress >= 1)
        .animation(DS.Anim.motion(DS.Anim.ease), value: refreshingHome)
    }

    private var coupleHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            ChatHomeCoupleAvatarColumn(
                name: myName,
                avatar: myAvatar,
                avatarURL: store.avatarURL(for: myUsername),
                image: .dog,
                status: statusMap[myUsername],
                online: store.connected,
                ring: DS.Palette.member(myUsername),
                editable: true,
                statusOptions: statusOptions,
                onStatusPick: { setStatus($0) }
            )
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 28, height: 1.5)
                        .overlay(
                            Rectangle()
                                .stroke(DS.Palette.pink.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        )
                    Text("💗")
                        .font(.system(size: 25))
                        .shadow(color: DS.Palette.pink.opacity(0.18), radius: 4, y: 1)
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 28, height: 1.5)
                        .overlay(
                            Rectangle()
                                .stroke(DS.Palette.pink.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        )
                }
                Text(connectionSummary)
                    .font(DS.Typo.micro.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(width: 70)

            ChatHomeCoupleAvatarColumn(
                name: partnerName,
                avatar: partnerAvatar,
                avatarURL: store.avatarURL(for: partnerUsername),
                image: .bunny,
                status: statusMap[partnerUsername],
                online: store.partnerOnline,
                ring: DS.Palette.member(partnerUsername),
                editable: false,
                statusOptions: statusOptions,
                onStatusPick: { _ in }
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var connectionSummary: String {
        if store.connectionState.isTransient { return "正在连接" }
        if !store.connected { return "实时连接不可用" }
        if !store.presenceKnown { return "正在获取在线状态" }
        return store.partnerOnline ? "都在线" : "等 TA 出现"
    }

    private var conversationWindowBackground: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [
                    theme.accent.color.opacity(0.12),
                    DS.Palette.innerSurface.opacity(0.92),
                    DS.Palette.pink.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(theme.accent.color.opacity(0.09))
                .rotationEffect(.degrees(-14))
                .offset(x: 13, y: 15)
            Image(systemName: "heart.fill")
                .font(.system(size: 17))
                .foregroundStyle(DS.Palette.pink.opacity(0.14))
                .offset(x: -40, y: -16)
        }
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.compact) {
                ForEach(statusOptions) { status in
                    ChatHomeStatusChip(
                        status: status,
                        selected: statusMap[myUsername] == status.title,
                        onTap: { toggleStatus(status) },
                        onEdit: { beginEditingStatus(status) },
                        onDelete: { deleteStatus(id: status.id) }
                    )
                }

                Button {
                    editingStatusID = nil
                    customStatusText = ""
                    showCustomStatusPrompt = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(DS.Typo.sectionLabel)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, 13)
                        .frame(height: 36)
                        .background(.white.opacity(0.52), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 1)
        }
    }

    private var actionStrip: some View {
        HStack(spacing: DS.Spacing.compact) {
            ForEach(ChatHomeCatalog.actions) { action in
                ChatHomeActionButton(
                    action: action,
                    sent: sentAction == action.id,
                    onTap: { send(action) }
                )
            }
        }
    }

    private var latestMessages: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最新消息", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(DS.Typo.button)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                if let last = coupleMessages.last {
                    Text(last.timeString)
                        .font(DS.Typo.micro.weight(.bold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.48), in: Capsule())
                }
            }

            if coupleMessages.isEmpty {
                Text("还没有消息，进去说第一句吧")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(coupleMessages.suffix(3))) { message in
                        let mine = message.sender == store.session?.username
                        let username = mine ? myUsername : message.sender
                        ChatHomeLatestRow(
                            message: message,
                            mine: mine,
                            avatarURL: store.avatarURL(for: username),
                            avatarText: store.avatarText(for: username),
                            accent: theme.accent.color,
                            preview: message.conversationalPreviewText
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .top)
        .background(conversationWindowBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(theme.accent.color.opacity(0.12), lineWidth: 1)
        )
    }

    private var enterChatButton: some View {
        Button {
            showChat = true
        } label: {
            HStack(spacing: 8) {
                Text("进入聊天")
                    .font(DS.Typo.button)
                Image(systemName: "arrow.right")
                    .font(DS.Typo.button)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                theme.accent.gradient,
                in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            )
            .shadow(color: theme.accent.color.opacity(0.22), radius: 10, y: 5)
        }
        .buttonStyle(PressableStyle())
    }

    /// 刷新结束后弹一条结果提示，1.8s 后自动消失（独立于下拉手势的生命周期）
    private func flashRefreshResult(_ result: HomeRefreshResult) {
        DS.Anim.withMotion(DS.Anim.ease) {
            refreshMessage = (result.dataUpdated || result.realtimeConnected) ? "刷新成功" : "刷新失败"
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                DS.Anim.withMotion(DS.Anim.ease) { refreshMessage = nil }
            }
        }
    }

    private func send(_ action: ChatHomeQuickAction) {
        Haptics.medium()
        if action.kind == .note {
            noteText = ""
            showNotePrompt = true
            return
        }
        store.sendInteraction(kind: action.kind, text: action.message, channel: .couple)
        DS.Anim.withMotion(DS.Anim.springFast) { sentAction = action.id }
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await MainActor.run {
                DS.Anim.withMotion(DS.Anim.ease) {
                    if sentAction == action.id { sentAction = nil }
                }
            }
        }
    }

    private func sendNote() {
        let raw = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = raw.isEmpty ? ChatHomeCatalog.randomNoteText() : String(raw.prefix(36))
        let message = "🪧 \(body)"
        store.sendInteraction(kind: .note, text: message, channel: .couple)
        DS.Anim.withMotion(DS.Anim.springFast) { sentAction = "note" }
        noteText = ""
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await MainActor.run {
                DS.Anim.withMotion(DS.Anim.ease) {
                    if sentAction == "note" { sentAction = nil }
                }
            }
        }
    }

    private func setStatus(_ status: ChatHomeStatusOption) {
        Haptics.selection()
        var next = statusMap
        next[myUsername] = status.title
        store.setShared("chat_statuses", value: next)
    }

    private func toggleStatus(_ status: ChatHomeStatusOption) {
        if statusMap[myUsername] == status.title {
            clearStatus()
        } else {
            setStatus(status)
        }
    }

    private func beginEditingStatus(_ status: ChatHomeStatusOption) {
        Haptics.medium()
        editingStatusID = status.id
        customStatusText = status.title
        showCustomStatusPrompt = true
    }

    private func clearStatus() {
        Haptics.selection()
        var next = statusMap
        next.removeValue(forKey: myUsername)
        store.setShared("chat_statuses", value: next)
    }

    private func saveStatusEditor() {
        let raw = customStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let title = String(raw.prefix(8))
        var list = storedStatuses
        if let editingStatusID,
           let index = list.firstIndex(where: { $0.id == editingStatusID }) {
            let oldTitle = list[index].title
            list[index].title = title
            saveStatuses(list)
            if statusMap[myUsername] == oldTitle {
                var next = statusMap
                next[myUsername] = title
                store.setShared("chat_statuses", value: next)
            }
        } else if !list.contains(where: { $0.title == title }) {
            list.append(ChatHomeStoredStatus(id: UUID().uuidString, title: title))
            saveStatuses(list)
            var next = statusMap
            next[myUsername] = title
            store.setShared("chat_statuses", value: next)
        } else if let existing = statusOptions.first(where: { $0.title == title }) {
            setStatus(existing)
        }
        editingStatusID = nil
        customStatusText = ""
    }

    private func deleteStatus(id: String) {
        Haptics.selection()
        let removed = storedStatuses.first(where: { $0.id == id })
        var list = storedStatuses.filter { $0.id != id }
        if list.isEmpty {
            list = ChatHomeCatalog.defaultStatuses
        }
        saveStatuses(list)
        if let removed, statusMap[myUsername] == removed.title {
            clearStatus()
        }
    }

    private func saveStatuses(_ list: [ChatHomeStoredStatus]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        statusesJSON = json
    }

    private func migratedDefaultStatuses() -> [ChatHomeStoredStatus] {
        var list = ChatHomeCatalog.defaultStatuses
        let legacy = legacyCustomStatusData
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for title in legacy {
            let trimmed = String(title.prefix(8))
            guard !list.contains(where: { $0.title == trimmed }) else { continue }
            list.append(ChatHomeStoredStatus(id: UUID().uuidString, title: trimmed))
        }
        saveStatuses(list)
        return list
    }

}
