import SwiftUI

// 聊天首页：把两个人的状态、互动和最近消息收进一张柔软的情侣卡片。
// 视觉块与模型拆到 Home/ 子目录，本文件只负责装配与状态逻辑。

struct ChatHomeView: View {
    private enum StatusPickerFollowUp {
        case add
        case edit(ChatHomeStatusOption)
    }

    private enum ConnectionNotice: Equatable {
        case connecting
        case connected
        case failed
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var timelineStore: ChatTimelineStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var showChat = false
    @State private var sentAction: String?
    @State private var showCustomStatusPrompt = false
    @State private var showStatusPicker = false
    @State private var statusPickerFollowUp: StatusPickerFollowUp?
    @State private var customStatusText = ""
    @State private var editingStatusID: String?
    @State private var showNotePrompt = false
    @State private var noteText = ""
    @State private var connectionNotice: ConnectionNotice?
    @State private var connectionNoticeToken = UUID()
    @AppStorage("chat_home_statuses_v2") private var statusesJSON = ""

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
        guard let raw = store.sharedValue("chat_statuses") else { return [:] }
        return raw.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String, !value.isEmpty {
                result[entry.key] = value
            }
        }
    }

    private var storedStatuses: [ChatHomeStoredStatus] {
        if !statusesJSON.isEmpty,
           let data = statusesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ChatHomeStoredStatus].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return ChatHomeCatalog.defaultStatuses
    }

    private var statusOptions: [ChatHomeStatusOption] {
        storedStatuses.enumerated().map { index, stored in
            ChatHomeCatalog.statusOption(stored: stored, index: index)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                mainPanel
                    .padding(.horizontal, DS.Spacing.page)
                    .padding(.top, 8)
                // 卡片外保留一小段真实的滚动缓冲，给底部标签栏留出呼吸空间。
                Color.clear.frame(height: 58)
            }
            .scrollIndicators(.hidden)
            .background(homePageBackground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) {
                ChatView().appSubpageChrome()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCoupleChatDeepLink)) { _ in
                showChat = true
            }
            .alert(editingStatusID == nil ? "添加状态" : "编辑状态", isPresented: $showCustomStatusPrompt) {
                TextField("比如：想被抱抱", text: $customStatusText)
                Button(editingStatusID == nil ? "添加并使用" : "保存") { saveStatusEditor() }
                if let editingStatusID {
                    Button("删除状态", role: .destructive) { deleteStatus(id: editingStatusID) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(editingStatusID == nil ? "添加后会立即设为我的状态。" : "修改后会同步更新当前正在使用的状态。")
            }
            .sheet(
                isPresented: $showStatusPicker,
                onDismiss: handleStatusPickerDismissed
            ) {
                ChatHomeStatusPickerSheet(
                    currentStatus: statusMap[myUsername],
                    options: statusOptions,
                    onPick: { option in
                        setStatus(option)
                        showStatusPicker = false
                    },
                    onAdd: {
                        statusPickerFollowUp = .add
                        showStatusPicker = false
                    },
                    onEdit: { option in
                        statusPickerFollowUp = .edit(option)
                        showStatusPicker = false
                    },
                    onDelete: { option in
                        deleteStatus(id: option.id)
                        showStatusPicker = false
                    },
                    onClear: {
                        clearStatus()
                        showStatusPicker = false
                    },
                    onClose: { showStatusPicker = false })
            }
            .alert("贴一张小纸条", isPresented: $showNotePrompt) {
                TextField("写一句想贴给 TA 的话", text: $noteText)
                Button("贴上去") { sendNote() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对方会被贴条挡住屏幕，需要手动撕掉。")
            }
            .overlay(alignment: .top) {
                connectionNoticeView
            }
            .onAppear { handleConnectionStateChange(from: nil, to: store.connectionState) }
            .onChange(of: store.connectionState) { oldState, newState in
                handleConnectionStateChange(from: oldState, to: newState)
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

            actionStrip
                .padding(.top, 12)
                .padding(.bottom, 12)

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
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Palette.hairline, lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .shadow(
            color: colorScheme == .dark ? .black.opacity(0.34) : .black.opacity(0.08),
            radius: 18,
            y: 7
        )
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
                        Color(red: 0.145, green: 0.14, blue: 0.17),
                        Color(red: 0.105, green: 0.105, blue: 0.13),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                LinearGradient(
                    colors: [theme.accent.color.opacity(0.035), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            } else {
                Color(red: 0.992, green: 0.988, blue: 0.99)
                LinearGradient(
                    colors: [theme.accent.color.opacity(0.025), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }

            HStack {
                Image(systemName: "sparkles")
                Spacer()
                Image(systemName: "heart.fill")
                    .font(DS.Typo.micro)
            }
            .font(DS.Typo.button)
            .foregroundStyle(theme.accent.color.opacity(colorScheme == .dark ? 0.14 : 0.16))
            .padding(.horizontal, 22)
            .padding(.top, 13)
        }
    }

    private var homePageBackground: some View {
        ZStack {
            DS.Palette.bgGradient
            LinearGradient(
                colors: [
                    theme.accent.color.opacity(colorScheme == .dark ? 0.10 : 0.07),
                    .clear,
                    theme.accent.color.opacity(colorScheme == .dark ? 0.04 : 0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var connectionNoticeView: some View {
        if let connectionNotice {
            HStack(spacing: 7) {
                if connectionNotice == .connecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent.color)
                } else {
                    Image(systemName: connectionNotice == .connected
                          ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(connectionNotice == .connected ? DS.Palette.green : DS.Palette.red)
                }
                Text(connectionNotice == .connecting
                     ? "连接中" : (connectionNotice == .connected ? "连接成功" : "连接失败"))
                    .font(DS.Typo.sectionLabel)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(theme.accent.color.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.10), radius: 7, y: 3)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(DS.Anim.ease, value: connectionNotice)
            .accessibilityLabel(connectionNotice == .connecting
                                ? "正在连接" : (connectionNotice == .connected ? "连接成功" : "连接失败"))
        }
    }

    private func handleConnectionStateChange(
        from oldState: RealtimeConnectionState?,
        to newState: RealtimeConnectionState
    ) {
        connectionNoticeToken = UUID()
        switch newState {
        case .connecting, .reconnecting:
            DS.Anim.withMotion(DS.Anim.ease) { connectionNotice = .connecting }
        case .connected:
            guard oldState?.isTransient == true || connectionNotice == .connecting else {
                connectionNotice = nil
                return
            }
            DS.Anim.withMotion(DS.Anim.ease) { connectionNotice = .connected }
            dismissConnectionNotice(after: 1.1)
        case .failed:
            DS.Anim.withMotion(DS.Anim.ease) { connectionNotice = .failed }
        case .disconnected:
            if oldState?.isTransient == true {
                DS.Anim.withMotion(DS.Anim.ease) { connectionNotice = .failed }
            }
        }
    }

    private func dismissConnectionNotice(after delay: TimeInterval) {
        let token = connectionNoticeToken
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard connectionNoticeToken == token else { return }
            await MainActor.run {
                DS.Anim.withMotion(DS.Anim.ease) { connectionNotice = nil }
            }
        }
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
                onStatusTap: { showStatusPicker = true }
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
                onStatusTap: {}
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
            DS.Palette.bgGradient
            LinearGradient(
                colors: [
                    theme.accent.color.opacity(colorScheme == .dark ? 0.08 : 0.05),
                    .clear,
                    theme.accent.color.opacity(colorScheme == .dark ? 0.03 : 0.025),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(theme.accent.color.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .rotationEffect(.degrees(-14))
                .offset(x: 13, y: 15)
            Image(systemName: "heart.fill")
                .font(.system(size: 17))
                .foregroundStyle(theme.accent.color.opacity(colorScheme == .dark ? 0.14 : 0.10))
                .offset(x: -40, y: -16)
        }
    }

    private var actionStrip: some View {
        HStack(spacing: DS.Spacing.compact) {
            ForEach(ChatHomeCatalog.actions) { action in
                ChatHomeActionButton(
                    action: action,
                    sent: sentAction == action.id,
                    disabled: sentAction != nil,
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
                        .background(DS.Palette.innerSurface, in: Capsule())
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
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .top)
        .background(conversationWindowBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(DS.Palette.hairline, lineWidth: 0.8)
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

    private func send(_ action: ChatHomeQuickAction) {
        if action.kind == .note {
            Haptics.medium()
            noteText = ""
            showNotePrompt = true
            return
        }
        guard store.sendInteraction(kind: action.kind, text: action.message, channel: .couple) else {
            return
        }
        Haptics.medium()
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

    private func beginAddingStatus() {
        Haptics.medium()
        editingStatusID = nil
        customStatusText = ""
        showCustomStatusPrompt = true
    }

    private func handleStatusPickerDismissed() {
        guard let followUp = statusPickerFollowUp else { return }
        statusPickerFollowUp = nil
        switch followUp {
        case .add:
            beginAddingStatus()
        case .edit(let option):
            beginEditingStatus(option)
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

}
