import SwiftUI

// 聊天首页：把两个人的状态、互动和最近消息收进一张柔软的情侣卡片。

struct ChatHomeView: View {
    @EnvironmentObject private var store: ChatStore
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

    private var statusMap: [String: String] {
        store.sharedValue("chat_statuses") as? [String: String] ?? [:]
    }

    private var storedStatuses: [StoredStatus] {
        if !statusesJSON.isEmpty,
           let data = statusesJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([StoredStatus].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return migratedDefaultStatuses()
    }

    private var statusOptions: [StatusOption] {
        storedStatuses.enumerated().map { index, stored in
            paletteOption(stored: stored, index: index)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                shortPullRefreshProbe
                mainPanel
                    .padding(.horizontal, DS.Spacing.page)
                    .padding(.top, 8)
                // 卡片外保留一小段真实的滚动缓冲，供下拉刷新和底部标签栏呼吸，
                // 不再把这块空间塞进「最新消息」里造成一片空白。
                Color.clear.frame(height: 58)
            }
            .coordinateSpace(name: "chatHomeScroll")
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .overlay(alignment: .top) { pullRefreshIndicator }
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
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill((refreshMessage == "刷新成功" ? DS.Palette.green : Color.red).opacity(0.92))
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
                .padding(.top, 22)
                .padding(.bottom, 18)

            coupleHeader
                .padding(.bottom, 20)

            sectionDivider

            statusStrip
                .padding(.top, 12)
                .padding(.bottom, 8)

            sectionDivider

            actionStrip
                .padding(.top, 8)
                .padding(.bottom, 12)

            sectionDivider

            latestMessages
                .padding(.top, 16)
                .padding(.bottom, 14)

            enterChatButton
                .padding(.bottom, 16)
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 0, alignment: .top)
        .background(homeCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.62), theme.accent.color.opacity(0.16)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: theme.accent.color.opacity(0.08), radius: 16, y: 6)
    }

    private var brandHeader: some View {
        VStack(spacing: 7) {
            ZStack {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                    Text("漫长悄悄话")
                        .font(.system(size: 35, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(
                    LinearGradient(
                        colors: [DS.Palette.blue, DS.Palette.purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: .white.opacity(0.95), radius: 3)

                Image(systemName: "heart.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Palette.pink.opacity(0.58))
                    .offset(y: -30)
            }

            Text("慢慢说，悄悄听")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent.color.opacity(0.62))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        DS.Palette.textSecondary.opacity(0.04),
                        DS.Palette.textSecondary.opacity(0.22),
                        DS.Palette.textSecondary.opacity(0.04),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }

    private var homeCardBackground: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    DS.Palette.cardSurface,
                    theme.accent.color.opacity(0.13),
                    DS.Palette.pink.opacity(0.075),
                    DS.Palette.cardSurface.opacity(0.96),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.white.opacity(0.58), theme.accent.color.opacity(0.07), .clear],
                center: .top,
                startRadius: 4,
                endRadius: 185
            )
            HStack {
                Image(systemName: "sparkles")
                Spacer()
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.accent.color.opacity(0.11))
            .padding(.horizontal, 22)
            .padding(.top, 13)
        }
    }

    private var shortPullRefreshProbe: some View {
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.Palette.accent)
                    .rotationEffect(.degrees(pullProgress >= 1 ? 180 : 0))
            }
        }
        .frame(width: 30, height: 30)
        .background(DS.Palette.innerSurface, in: Circle())
        .opacity(refreshingHome ? 1 : pullProgress)
        .scaleEffect(refreshingHome ? 1 : 0.6 + 0.4 * pullProgress)
        .padding(.top, 8)
        .animation(DS.Anim.springFast, value: pullProgress >= 1)
        .animation(DS.Anim.ease, value: refreshingHome)
    }

    private var coupleHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            CoupleAvatarColumn(
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(width: 70)

            CoupleAvatarColumn(
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

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(statusOptions) { status in
                    statusChip(status)
                }

                Button {
                    editingStatusID = nil
                    customStatusText = ""
                    showCustomStatusPrompt = true
                } label: {
                    Label("添加", systemImage: "plus")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
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

    private func statusChip(_ status: StatusOption) -> some View {
        let selected = statusMap[myUsername] == status.title
        return Button {
            toggleStatus(status)
        } label: {
            HStack(spacing: 6) {
                if selected {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }
                Text(status.title)
                    .lineLimit(1)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(selected ? status.color : DS.Palette.textPrimary.opacity(0.72))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule().fill(
                    selected
                        ? AnyShapeStyle(status.color.opacity(0.14))
                        : AnyShapeStyle(.white.opacity(0.52))
                )
            )
            .overlay(Capsule().stroke(selected ? status.color.opacity(0.22) : .white.opacity(0.72), lineWidth: 1))
            .shadow(color: selected ? status.color.opacity(0.12) : .clear, radius: 7, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button {
                beginEditingStatus(status)
            } label: {
                Label("编辑状态", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteStatus(id: status.id)
            } label: {
                Label("删除状态", systemImage: "trash")
            }
        }
        .accessibilityHint("点按切换状态，长按可编辑或删除")
    }

    private var actionStrip: some View {
        HStack(spacing: 8) {
            ForEach(Self.actions) { action in
                actionButton(action)
            }
        }
    }

    private func actionButton(_ action: QuickAction) -> some View {
        let sent = sentAction == action.id
        return Button {
            send(action)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    // 柔和渐变 + 细描边取代大块纯色，跟卡片的玻璃感统一
                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [action.background.opacity(0.82), action.background.opacity(0.42)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                                .stroke(.white.opacity(0.5), lineWidth: 1)
                        }
                        .frame(height: 40)
                    Text(sent ? "✓" : action.emoji)
                        .font(.system(size: 22, weight: .bold))
                        .contentTransition(.numericText())
                }
                Text(action.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .disabled(sent)
    }

    private var latestMessages: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("最新消息", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                if let last = store.messages.last {
                    Text(last.timeString)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.48), in: Capsule())
                }
            }

            if store.messages.isEmpty {
                Text("还没有消息，进去说第一句吧")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(store.messages.suffix(3))) { message in
                        latestRow(message)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .top)
        .background(conversationWindowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(theme.accent.color.opacity(0.12), lineWidth: 1)
        )
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
                    DS.Palette.pink.opacity(0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
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

    private func latestRow(_ message: ChatMessage) -> some View {
        let mine = message.sender == store.session?.username
        return HStack(alignment: .bottom, spacing: 8) {
            if !mine {
                latestAvatar(for: message)
            } else {
                Spacer(minLength: 54)
            }

            Text(preview(message))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(mine ? DS.Palette.textPrimary : DS.Palette.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    mine ? theme.accent.color.opacity(0.16) : Color.white.opacity(0.62),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(mine ? theme.accent.color.opacity(0.12) : .white.opacity(0.56), lineWidth: 1)
                )

            if mine {
                latestAvatar(for: message)
            } else {
                Spacer(minLength: 54)
            }
        }
    }

    private func latestAvatar(for message: ChatMessage) -> some View {
        let mine = message.sender == store.session?.username
        let username = mine ? myUsername : message.sender
        return AvatarBadge(
            url: store.avatarURL(for: username),
            fallbackEmoji: store.avatarText(for: username),
            size: 31,
            background: .white.opacity(0.7))
    }

    private var enterChatButton: some View {
        Button {
            Haptics.medium()
            showChat = true
        } label: {
            HStack(spacing: 8) {
                Text("进入聊天")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .heavy))
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
        withAnimation(DS.Anim.ease) {
            refreshMessage = (result.dataUpdated || result.realtimeConnected) ? "刷新成功" : "刷新失败"
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run {
                withAnimation(DS.Anim.ease) { refreshMessage = nil }
            }
        }
    }

    private func preview(_ message: ChatMessage) -> String {
        switch message.type {
        case "sticker": return "[表情]"
        case "image": return "[图片]"
        case "video": return "[视频]"
        case "voice": return "[语音]"
        case "file": return "[文件]"
        default: return message.displayText
        }
    }

    private func send(_ action: QuickAction) {
        Haptics.medium()
        if action.kind == .note {
            noteText = ""
            showNotePrompt = true
            return
        }
        store.sendInteraction(kind: action.kind, text: action.message, channel: .couple)
        withAnimation(DS.Anim.springFast) { sentAction = action.id }
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await MainActor.run {
                withAnimation(DS.Anim.ease) {
                    if sentAction == action.id { sentAction = nil }
                }
            }
        }
    }

    private func sendNote() {
        let raw = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = raw.isEmpty ? Self.randomNoteText() : String(raw.prefix(36))
        let message = "🪧 \(body)"
        store.sendInteraction(kind: .note, text: message, channel: .couple)
        withAnimation(DS.Anim.springFast) { sentAction = "note" }
        noteText = ""
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await MainActor.run {
                withAnimation(DS.Anim.ease) {
                    if sentAction == "note" { sentAction = nil }
                }
            }
        }
    }

    private func setStatus(_ status: StatusOption) {
        Haptics.selection()
        var next = statusMap
        next[myUsername] = status.title
        store.setShared("chat_statuses", value: next)
    }

    private func toggleStatus(_ status: StatusOption) {
        if statusMap[myUsername] == status.title {
            clearStatus()
        } else {
            setStatus(status)
        }
    }

    private func beginEditingStatus(_ status: StatusOption) {
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
            list.append(StoredStatus(id: UUID().uuidString, title: title))
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
            list = Self.defaultStatuses
        }
        saveStatuses(list)
        if let removed, statusMap[myUsername] == removed.title {
            clearStatus()
        }
    }

    private func saveStatuses(_ list: [StoredStatus]) {
        guard let data = try? JSONEncoder().encode(list),
              let json = String(data: data, encoding: .utf8) else { return }
        statusesJSON = json
    }

    private func migratedDefaultStatuses() -> [StoredStatus] {
        var list = Self.defaultStatuses
        let legacy = legacyCustomStatusData
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for title in legacy {
            let trimmed = String(title.prefix(8))
            guard !list.contains(where: { $0.title == trimmed }) else { continue }
            list.append(StoredStatus(id: UUID().uuidString, title: trimmed))
        }
        saveStatuses(list)
        return list
    }

    private func paletteOption(stored: StoredStatus, index: Int) -> StatusOption {
        let palette = Self.statusPalettes[index % Self.statusPalettes.count]
        return StatusOption(id: stored.id, title: stored.title, color: palette.color)
    }

    private struct StoredStatus: Codable, Identifiable, Equatable {
        let id: String
        var title: String
    }

    private struct StatusPalette {
        let color: Color
    }

    private static let defaultStatuses: [StoredStatus] = [
        .init(id: "miss", title: "在想你"),
        .init(id: "cling", title: "想贴贴"),
        .init(id: "busy", title: "忙完找你"),
        .init(id: "kiss", title: "要亲亲"),
    ]

    private static let statusPalettes: [StatusPalette] = [
        .init(color: Color(red: 0.78, green: 0.28, blue: 0.46)),
        .init(color: Color(red: 0.72, green: 0.30, blue: 0.48)),
        .init(color: Color(red: 0.38, green: 0.56, blue: 0.82)),
        .init(color: Color(red: 0.82, green: 0.54, blue: 0.26)),
    ]

    private static func randomNoteText() -> String {
        [
            "先别划走，想你一下",
            "今天也要被我惦记",
            "看到这里就亲亲",
            "把坏心情撕掉",
            "给你贴一朵小开心",
        ].randomElement() ?? "想你一下"
    }

    fileprivate struct StatusOption: Identifiable {
        let id: String
        let title: String
        let color: Color
    }

    fileprivate struct QuickAction: Identifiable {
        let id: String
        let emoji: String
        let title: String
        let message: String
        let background: Color
        let kind: InteractionEffectKind
    }

    private static let actions: [QuickAction] = [
        .init(id: "miss", emoji: "💗", title: "想你了", message: "💗 想你了", background: Color(red: 1.00, green: 0.91, blue: 0.95), kind: .miss),
        .init(id: "pat", emoji: "🖐️", title: "拍一拍", message: "🖐️ 拍了拍你", background: Color(red: 1.00, green: 0.94, blue: 0.86), kind: .pat),
        .init(id: "flower", emoji: "🌸", title: "送花花", message: "🌸 送你一朵花花", background: Color(red: 1.00, green: 0.91, blue: 0.94), kind: .flower),
        .init(id: "poop", emoji: "💩", title: "扔粑粑", message: "💩 扔了个粑粑", background: Color(red: 0.96, green: 0.91, blue: 0.83), kind: .poop),
        .init(id: "note", emoji: "🪧", title: "贴条", message: "🪧 给你贴了一张小纸条", background: Color(red: 0.94, green: 0.95, blue: 0.97), kind: .note),
    ]
}

private struct CoupleAvatarColumn: View {
    let name: String
    let avatar: String
    var avatarURL: URL? = nil
    let image: AvatarArt
    let status: String?
    let online: Bool
    let ring: Color
    let editable: Bool
    let statusOptions: [ChatHomeView.StatusOption]
    let onStatusPick: (ChatHomeView.StatusOption) -> Void
    @State private var showStatusPicker = false

    var body: some View {
        VStack(spacing: 9) {
            statusCapsule

            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarURL {
                        CachedImage(url: avatarURL) {
                            AvatarIllustration(kind: image, fallback: avatar)
                        }
                    } else {
                        AvatarIllustration(kind: image, fallback: avatar)
                    }
                }
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 4))
                    .shadow(color: ring.opacity(0.18), radius: 10, y: 5)

                Circle()
                    .fill(online ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 4))
                    .offset(x: -9, y: -10)
            }

            Text(name)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    @ViewBuilder
    private var statusCapsule: some View {
        if editable {
            Button {
                Haptics.light()
                showStatusPicker = true
            } label: {
                Text(status ?? "加状态")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.pink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.64), in: Capsule())
            }
            .frame(minWidth: 76, minHeight: 34)
            .contentShape(Capsule())
            .buttonStyle(PressableStyle())
            .confirmationDialog("选择状态", isPresented: $showStatusPicker, titleVisibility: .visible) {
                ForEach(statusOptions) { option in
                    Button(option.title) { onStatusPick(option) }
                }
            }
            .contextMenu {
                ForEach(statusOptions) { option in
                    Button(option.title) { onStatusPick(option) }
                }
            }
        } else {
            Text(status ?? "想贴贴")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary.opacity(0.62))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.54), in: Capsule())
        }
    }
}

private enum AvatarArt {
    case dog
    case bunny
}

private struct AvatarIllustration: View {
    let kind: AvatarArt
    let fallback: String

    var body: some View {
        ZStack {
            // 半透明柔光底，透出卡片玻璃感，避免大块纯白
            LinearGradient(
                colors: [Color.white.opacity(0.75), Color(red: 1.0, green: 0.95, blue: 0.97).opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            decorativeMarks
            Text(fallback)
                .font(.system(size: 38))
                .offset(y: 6)
        }
    }

    @ViewBuilder
    private var decorativeMarks: some View {
        switch kind {
        case .dog:
            Image(systemName: "bone.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.56).opacity(0.22))
                .offset(x: 28, y: -30)
            Circle()
                .fill(Color(red: 0.97, green: 0.57, blue: 0.68).opacity(0.28))
                .frame(width: 18, height: 18)
                .offset(x: -32, y: -28)
        case .bunny:
            Image(systemName: "heart.fill")
                .font(.system(size: 18))
                .foregroundStyle(DS.Palette.pink.opacity(0.22))
                .offset(x: -32, y: -32)
            Image(systemName: "sparkle")
                .font(.system(size: 20))
                .foregroundStyle(DS.Palette.pink.opacity(0.30))
                .offset(x: 32, y: -24)
        }
    }
}
