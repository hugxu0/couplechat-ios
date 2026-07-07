import SwiftUI

// 聊天首页：把两个人的状态、互动和最近消息收进一张柔软的情侣卡片。

struct ChatHomeView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var showChat = false
    @State private var sentAction: String?

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pageTitle
                    mainPanel
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, 26)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) { ChatView() }
        }
    }

    private var pageTitle: some View {
        Text("聊天")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(DS.Palette.textPrimary)
            .padding(.top, 4)
            .padding(.horizontal, 4)
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            coupleHeader
                .padding(.top, 24)
                .padding(.bottom, 18)

            Divider().opacity(0.38)

            statusStrip
                .padding(.vertical, 16)

            Divider().opacity(0.38)

            actionStrip
                .padding(.vertical, 18)

            Divider().opacity(0.38)

            latestMessages
                .padding(.top, 18)
                .padding(.bottom, 18)

            enterChatButton
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(DS.Palette.cardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(.white.opacity(0.55), lineWidth: 1)
                }
        )
        .shadow(color: DS.Surface.shadow, radius: 18, y: 8)
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
                        .frame(width: 32, height: 2)
                    Text("💗")
                        .font(.system(size: 29))
                        .shadow(color: DS.Palette.pink.opacity(0.24), radius: 6, y: 2)
                    Rectangle()
                        .fill(DS.Palette.pink.opacity(0.38))
                        .frame(width: 32, height: 2)
                }
                Text(store.partnerOnline ? "都在线" : "等 TA 出现")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(width: 78)

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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(Self.statusOptions) { status in
                    let selected = statusMap[myUsername] == status.title
                    Button {
                        setStatus(status)
                    } label: {
                        Text(status.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(selected ? .white : status.color)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selected ? AnyShapeStyle(status.gradient) : AnyShapeStyle(DS.Palette.innerSurface))
                            )
                    }
                    .buttonStyle(PressableStyle())
                }

                Button {
                    clearStatus()
                } label: {
                    Image(systemName: statusMap[myUsername] == nil ? "plus" : "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 44, height: 40)
                        .background(DS.Palette.innerSurface, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 1)
        }
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
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(action.background)
                        .frame(height: 74)
                    Text(sent ? "✓" : action.emoji)
                        .font(.system(size: sent ? 30 : 29, weight: .bold))
                        .contentTransition(.numericText())
                }
                Text(action.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(action.subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if let last = store.messages.last {
                    Text(last.timeString)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            if store.messages.isEmpty {
                Text("还没有消息，进去说第一句吧")
                    .font(.system(size: 14, weight: .medium))
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
                .font(.system(size: 15, weight: .bold, design: .rounded))
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
            .font(.system(size: 23))
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.7), in: Circle())
    }

    private var enterChatButton: some View {
        Button {
            Haptics.medium()
            showChat = true
        } label: {
            HStack(spacing: 8) {
                Text("进入聊天")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
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
        default: return message.text
        }
    }

    private func send(_ action: QuickAction) {
        Haptics.medium()
        store.sendText(action.message, channel: .couple)
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
    }

    private static let actions: [QuickAction] = [
        .init(id: "miss", emoji: "💗", title: "想你了", subtitle: "心跳波纹", message: "💗 想你了", background: Color(red: 1.00, green: 0.91, blue: 0.95)),
        .init(id: "pat", emoji: "🖐️", title: "拍一拍", subtitle: "轻轻碰一下", message: "🖐️ 拍了拍你", background: Color(red: 1.00, green: 0.94, blue: 0.86)),
        .init(id: "flower", emoji: "🌸", title: "送花花", subtitle: "送你一朵", message: "🌸 送你一朵花花", background: Color(red: 1.00, green: 0.91, blue: 0.94)),
        .init(id: "poop", emoji: "💩", title: "扔粑粑", subtitle: "坏笑一下", message: "💩 扔了一个坏坏的小粑粑", background: Color(red: 0.96, green: 0.91, blue: 0.83)),
        .init(id: "note", emoji: "🪧", title: "贴条", subtitle: "贴张便利贴", message: "🪧 给你贴了一张小纸条", background: Color(red: 0.94, green: 0.95, blue: 0.97)),
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
                    .frame(width: 118, height: 118)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 4))
                    .shadow(color: ring.opacity(0.18), radius: 10, y: 5)

                Circle()
                    .fill(online ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.55))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 4))
                    .offset(x: -9, y: -10)
            }

            Text(name)
                .font(.system(size: 23, weight: .heavy, design: .rounded))
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
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.pink)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.64), in: Capsule())
            }
        } else {
            Text(status ?? "想贴贴")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary.opacity(0.62))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
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
            LinearGradient(
                colors: [Color.white, Color(red: 1.0, green: 0.95, blue: 0.97)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            decorativeMarks
            Text(fallback)
                .font(.system(size: 50))
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
