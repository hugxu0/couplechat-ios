import SwiftUI

// 聊天首页：把两个人的状态、互动和最近消息收进一张柔软的情侣卡片。

struct ChatHomeView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var showChat = false
    @State private var sentAction: String?
    @State private var showCustomStatusPrompt = false
    @State private var customStatusText = ""
    @State private var showNotePrompt = false
    @State private var noteText = ""
    @State private var editingCustomStatuses = false
    @AppStorage("chat_home_custom_statuses") private var customStatusData = ""

    private var myName: String { store.session?.name ?? "小旭" }
    private var myUsername: String { store.session?.username ?? "xu" }
    private var myAvatar: String { AccountPresentation.avatar(for: myUsername) }
    private var partnerName: String { store.partner?.name ?? "小偲" }
    private var partnerUsername: String { store.partner?.username ?? (myUsername == "xu" ? "si" : "xu") }
    private var partnerAvatar: String {
        store.partner?.avatar ?? AccountPresentation.avatar(for: partnerUsername)
    }

    private var statusMap: [String: String] {
        store.sharedValue("chat_statuses") as? [String: String] ?? [:]
    }

    private var customStatuses: [String] {
        get {
            customStatusData
                .split(separator: "\n")
                .map { String($0) }
                .filter { !$0.isEmpty }
        }
        nonmutating set {
            var seen = Set<String>()
            let values = newValue
                .map { String($0.prefix(8)) }
                .filter { !$0.isEmpty }
                .filter { seen.insert($0).inserted }
            customStatusData = values.joined(separator: "\n")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    mainPanel
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) { ChatView() }
            .alert("自定义状态", isPresented: $showCustomStatusPrompt) {
                TextField("比如：想被抱抱", text: $customStatusText)
                Button("保存") { setCustomStatus() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会显示在你的头像上方，尽量短一点。")
            }
            .alert("贴一张小纸条", isPresented: $showNotePrompt) {
                TextField("写一句想贴给 TA 的话", text: $noteText)
                Button("贴上去") { sendNote() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("对方会被贴条挡住屏幕，需要手动撕掉。")
            }
        }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            coupleHeader
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider().opacity(0.38)

            statusStrip
                .padding(.vertical, 12)

            Divider().opacity(0.38)

            actionStrip
                .padding(.vertical, 13)

            Divider().opacity(0.38)

            latestMessages
                .padding(.top, 14)
                .padding(.bottom, 14)

            enterChatButton
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    private var coupleHeader: some View {
        HStack(alignment: .center, spacing: 0) {
            CoupleAvatarColumn(
                name: myName,
                avatar: myAvatar,
                image: .dog,
                status: statusMap[myUsername],
                online: store.connected,
                ring: DS.Palette.member(myUsername),
                editable: true,
                statusOptions: Self.statusOptions,
                onStatusPick: { setStatus($0) }
            )
            .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    Rectangle()
                        .fill(DS.Palette.pink.opacity(0.38))
                        .frame(width: 28, height: 2)
                    Text("💗")
                        .font(.system(size: 25))
                        .shadow(color: DS.Palette.pink.opacity(0.24), radius: 6, y: 2)
                    Rectangle()
                        .fill(DS.Palette.pink.opacity(0.38))
                        .frame(width: 28, height: 2)
                }
                Text(store.partnerOnline ? "都在线" : "等 TA 出现")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(width: 70)

            CoupleAvatarColumn(
                name: partnerName,
                avatar: partnerAvatar,
                image: .bunny,
                status: statusMap[partnerUsername],
                online: store.partnerOnline,
                ring: DS.Palette.member(partnerUsername),
                editable: false,
                statusOptions: Self.statusOptions,
                onStatusPick: { _ in }
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.statusOptions) { status in
                        statusButton(status)
                    }

                    Button {
                        customStatusText = ""
                        showCustomStatusPrompt = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .frame(width: 38, height: 34)
                            .background(DS.Palette.innerSurface, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())

                    if statusMap[myUsername] != nil {
                        Button {
                            clearStatus()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(DS.Palette.textSecondary)
                                .frame(width: 34, height: 34)
                                .background(DS.Palette.innerSurface, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 1)
            }

            if !customStatuses.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(customStatuses, id: \.self) { title in
                            customStatusButton(title)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private func statusButton(_ status: StatusOption) -> some View {
        let selected = statusMap[myUsername] == status.title
        return Button {
            setStatus(status)
        } label: {
            Text(status.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? .white : status.color)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selected ? AnyShapeStyle(status.gradient) : AnyShapeStyle(DS.Palette.innerSurface))
                )
        }
        .buttonStyle(PressableStyle())
    }

    private func customStatusButton(_ title: String) -> some View {
        let selected = statusMap[myUsername] == title
        return ZStack(alignment: .topTrailing) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? .white : DS.Palette.textPrimary.opacity(0.72))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selected ? AnyShapeStyle(customStatusOption(title).gradient) : AnyShapeStyle(DS.Palette.innerSurface))
                )
                .rotationEffect(.degrees(editingCustomStatuses ? (title.hashValue.isMultiple(of: 2) ? 1.8 : -1.8) : 0))
                .animation(editingCustomStatuses ? .easeInOut(duration: 0.11).repeatForever(autoreverses: true) : .default, value: editingCustomStatuses)

            if editingCustomStatuses {
                Button {
                    deleteCustomStatus(title)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -6)
            }
        }
        .contentShape(Capsule())
        .onTapGesture {
            if editingCustomStatuses {
                withAnimation(DS.Anim.springFast) { editingCustomStatuses = false }
            } else {
                setStatus(customStatusOption(title))
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35)
                .onEnded { _ in
                    Haptics.medium()
                    withAnimation(DS.Anim.springFast) { editingCustomStatuses = true }
                }
        )
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
            VStack(spacing: 6) {
                ZStack {
                    // 柔和渐变 + 细描边取代大块纯色，跟卡片的玻璃感统一
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [action.background.opacity(0.82), action.background.opacity(0.42)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(.white.opacity(0.5), lineWidth: 1)
                        }
                        .frame(height: 58)
                    Text(sent ? "✓" : action.emoji)
                        .font(.system(size: sent ? 27 : 26, weight: .bold))
                        .contentTransition(.numericText())
                }
                Text(action.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(action.subtitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .disabled(sent)
    }

    private var latestMessages: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("最新消息")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if let last = store.messages.last {
                    Text(last.timeString)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
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
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(mine ? DS.Palette.pink.opacity(0.14) : DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

            if mine {
                latestAvatar(for: message)
            } else {
                Spacer(minLength: 54)
            }
        }
    }

    private func latestAvatar(for message: ChatMessage) -> some View {
        Text(message.sender == store.session?.username ? myAvatar : partnerAvatar)
            .font(.system(size: 21))
            .frame(width: 31, height: 31)
            .background(.white.opacity(0.7), in: Circle())
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
            .padding(.vertical, 15)
            .background(
                LinearGradient(
                    colors: [DS.Palette.pink.opacity(0.92), theme.accent.colorAlt],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(color: DS.Palette.pink.opacity(0.22), radius: 10, y: 5)
        }
        .buttonStyle(PressableStyle())
    }

    private func preview(_ message: ChatMessage) -> String {
        switch message.type {
        case "image", "sticker": return "[图片]"
        case "video": return "[视频]"
        case "voice": return "[语音]"
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
        let text = InteractionPayload.encode(kind: action.kind, text: action.message)
        store.sendText(text, channel: .couple)
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
        store.setShared("screen_note", value: [
            "id": UUID().uuidString,
            "from": myUsername,
            "fromName": myName,
            "text": message,
            "ts": Date().timeIntervalSince1970 * 1000,
        ])
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

    private func clearStatus() {
        Haptics.selection()
        var next = statusMap
        next.removeValue(forKey: myUsername)
        store.setShared("chat_statuses", value: next)
    }

    private func setCustomStatus() {
        let raw = customStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let title = String(raw.prefix(8))
        var stored = customStatuses
        if !stored.contains(title) {
            stored.append(title)
            customStatuses = stored
        }
        var next = statusMap
        next[myUsername] = title
        store.setShared("chat_statuses", value: next)
    }

    private func deleteCustomStatus(_ title: String) {
        Haptics.selection()
        withAnimation(DS.Anim.springFast) {
            customStatuses = customStatuses.filter { $0 != title }
            if customStatuses.isEmpty {
                editingCustomStatuses = false
            }
        }
        if statusMap[myUsername] == title {
            clearStatus()
        }
    }

    private func customStatusOption(_ title: String) -> StatusOption {
        .init(
            id: "custom-\(title)",
            title: title,
            color: DS.Palette.pink,
            gradient: LinearGradient(
                colors: [Color(red: 1.00, green: 0.53, blue: 0.72), Color(red: 1.00, green: 0.73, blue: 0.85)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

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
        let gradient: LinearGradient
    }

    private static let statusOptions: [StatusOption] = [
        .init(id: "miss", title: "在想你", color: DS.Palette.pink,
              gradient: LinearGradient(colors: [Color(red: 1.00, green: 0.44, blue: 0.62), Color(red: 1.00, green: 0.67, blue: 0.76)], startPoint: .leading, endPoint: .trailing)),
        .init(id: "cling", title: "想贴贴", color: Color(red: 0.82, green: 0.34, blue: 0.58),
              gradient: LinearGradient(colors: [Color(red: 0.96, green: 0.52, blue: 0.76), Color(red: 1.00, green: 0.76, blue: 0.86)], startPoint: .leading, endPoint: .trailing)),
        .init(id: "busy", title: "忙完找你", color: Color(red: 0.34, green: 0.54, blue: 0.95),
              gradient: LinearGradient(colors: [Color(red: 0.35, green: 0.58, blue: 1.00), Color(red: 0.54, green: 0.76, blue: 1.00)], startPoint: .leading, endPoint: .trailing)),
        .init(id: "kiss", title: "要亲亲", color: Color(red: 0.82, green: 0.54, blue: 0.18),
              gradient: LinearGradient(colors: [Color(red: 0.95, green: 0.63, blue: 0.22), Color(red: 1.00, green: 0.78, blue: 0.44)], startPoint: .leading, endPoint: .trailing)),
    ]

    fileprivate struct QuickAction: Identifiable {
        let id: String
        let emoji: String
        let title: String
        let subtitle: String
        let message: String
        let background: Color
        let kind: InteractionEffectKind
    }

    private static let actions: [QuickAction] = [
        .init(id: "miss", emoji: "💗", title: "想你了", subtitle: "心跳波纹", message: "💗 想你了", background: Color(red: 1.00, green: 0.91, blue: 0.95), kind: .miss),
        .init(id: "pat", emoji: "🖐️", title: "拍一拍", subtitle: "轻轻碰一下", message: "🖐️ 拍了拍你", background: Color(red: 1.00, green: 0.94, blue: 0.86), kind: .pat),
        .init(id: "flower", emoji: "🌸", title: "送花花", subtitle: "送你一朵", message: "🌸 送你一朵花花", background: Color(red: 1.00, green: 0.91, blue: 0.94), kind: .flower),
        .init(id: "poop", emoji: "💩", title: "扔粑粑", subtitle: "扔了个粑粑", message: "💩 扔了个粑粑", background: Color(red: 0.96, green: 0.91, blue: 0.83), kind: .poop),
        .init(id: "note", emoji: "🪧", title: "贴条", subtitle: "贴住屏幕", message: "🪧 给你贴了一张小纸条", background: Color(red: 0.94, green: 0.95, blue: 0.97), kind: .note),
    ]
}

private struct CoupleAvatarColumn: View {
    let name: String
    let avatar: String
    let image: AvatarArt
    let status: String?
    let online: Bool
    let ring: Color
    let editable: Bool
    let statusOptions: [ChatHomeView.StatusOption]
    let onStatusPick: (ChatHomeView.StatusOption) -> Void

    var body: some View {
        VStack(spacing: 9) {
            statusCapsule

            ZStack(alignment: .bottomTrailing) {
                AvatarIllustration(kind: image, fallback: avatar)
                    .frame(width: 104, height: 104)
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
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    @ViewBuilder
    private var statusCapsule: some View {
        if editable {
            Menu {
                ForEach(statusOptions) { option in
                    Button(option.title) {
                        onStatusPick(option)
                    }
                }
            } label: {
                Text(status ?? "加状态")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.pink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.64), in: Capsule())
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
                .font(.system(size: 45))
                .offset(y: 8)
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
