import SwiftUI

// 聊天首页：以「两个人此刻的联结」为主角。
// 结构：时间问候 → 在场卡（头像+心跳联结+在线状态）→ 对话一瞥（整卡进入聊天）→ 悄悄递话。
// 大橘入口已移到宠物页底部。互动按钮发送真实消息，不做假占位。

struct ChatHomeView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showChat = false
    @State private var sentNudge: String?

    private var myName: String { store.session?.name ?? "小旭" }
    private var myUsername: String { store.session?.username ?? "xu" }
    private var myAvatar: String { AccountPresentation.avatar(for: myUsername) }
    private var partnerName: String { store.partner?.name ?? "小偲" }
    private var partnerUsername: String { store.partner?.username ?? (myUsername == "xu" ? "si" : "xu") }
    private var partnerAvatar: String {
        store.partner?.avatar ?? AccountPresentation.avatar(for: partnerUsername)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.gap) {
                    greeting
                    presenceCard
                    conversationCard
                    nudgeCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) { ChatView() }
        }
    }

    // MARK: 时间问候（页面开场）
    private var greeting: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(greetingText)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
            Text("和 \(partnerName) 的悄悄话")
                .font(.system(size: 15))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let time: String
        switch hour {
        case 5..<11: time = "早安"
        case 11..<13: time = "中午好"
        case 13..<18: time = "下午好"
        case 18..<23: time = "晚上好"
        default: time = "夜深了"
        }
        return "\(time)，\(myName)"
    }

    // MARK: 在场卡（签名元素）
    private var presenceCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 0) {
                PresenceAvatar(
                    emoji: myAvatar, name: myName,
                    ring: DS.Palette.member(myUsername),
                    online: store.connected, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)

                HeartbeatLink(alive: store.connected && store.partnerOnline, reduceMotion: reduceMotion)
                    .frame(width: 76)

                PresenceAvatar(
                    emoji: partnerAvatar, name: partnerName,
                    ring: DS.Palette.member(partnerUsername),
                    online: store.partnerOnline, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)
            }

            Text(presenceLine)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, DS.Spacing.card)
        .dsCard()
    }

    private var presenceLine: String {
        if !store.connected { return "正在连接…" }
        if store.partnerOnline { return "你们都在线，说点什么吧" }
        return "\(partnerName) 还没上线，先留句话给 TA"
    }

    // MARK: 对话一瞥（整卡进入聊天）
    private var conversationCard: some View {
        Button {
            Haptics.light()
            showChat = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近的话")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    if let last = store.messages.last {
                        Text(last.timeString)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }

                if store.messages.isEmpty {
                    Text("还没有消息，进去说第一句吧")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.messages.suffix(2)) { m in
                            glimpseBubble(
                                preview(m),
                                mine: m.sender == store.session?.username)
                        }
                    }
                }

                HStack(spacing: 5) {
                    Spacer()
                    Text("进入聊天")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(theme.accent.color)
                .padding(.top, 2)
            }
            .padding(DS.Spacing.card)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
        }
        .buttonStyle(PressableStyle())
    }

    private func preview(_ m: ChatMessage) -> String {
        switch m.type {
        case "image": return "[图片]"
        case "video": return "[视频]"
        case "sticker": return "[表情]"
        case "voice": return "[语音]"
        default: return m.text
        }
    }

    private func glimpseBubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(mine ? AnyShapeStyle(theme.accent.color) : AnyShapeStyle(DS.Palette.innerSurface))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }

    // MARK: 悄悄递话（发送真实消息）
    private var nudgeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("悄悄递给 TA")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Palette.textPrimary)

            HStack(spacing: 10) {
                ForEach(Self.nudges, id: \.label) { nudge in
                    nudgeButton(nudge)
                }
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func nudgeButton(_ nudge: Nudge) -> some View {
        let sent = sentNudge == nudge.label
        return Button {
            send(nudge)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(theme.accent.color.opacity(0.12))
                        .frame(width: 52, height: 52)
                    Image(systemName: sent ? "checkmark" : nudge.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(sent ? "已送出" : nudge.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(sent ? theme.accent.color : DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .disabled(sent)
    }

    private func send(_ nudge: Nudge) {
        Haptics.medium()
        store.sendText(nudge.message, channel: .couple)
        withAnimation(DS.Anim.springFast) { sentNudge = nudge.label }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                withAnimation(DS.Anim.ease) {
                    if sentNudge == nudge.label { sentNudge = nil }
                }
            }
        }
    }

    private struct Nudge {
        let symbol: String
        let label: String
        let message: String
    }

    private static let nudges: [Nudge] = [
        .init(symbol: "heart.fill", label: "想你", message: "💗 突然有点想你了"),
        .init(symbol: "hands.and.sparkles.fill", label: "抱抱", message: "🤗 给你一个抱抱"),
        .init(symbol: "sun.max.fill", label: "早安", message: "☀️ 早安呀"),
        .init(symbol: "moon.stars.fill", label: "晚安", message: "🌙 晚安，好梦"),
    ]
}

// MARK: - 在场头像（呼吸光环 + 在线圆点）

private struct PresenceAvatar: View {
    let emoji: String
    let name: String
    let ring: Color
    let online: Bool
    let reduceMotion: Bool

    @State private var breathe = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // 柔光底（在线时更亮）
                Circle()
                    .fill(ring.opacity(online ? 0.22 : 0.08))
                    .frame(width: 96, height: 96)
                    .blur(radius: 10)
                // 呼吸光环
                Circle()
                    .stroke(ring.opacity(online ? 0.85 : 0.28), lineWidth: 2.5)
                    .frame(width: 86, height: 86)
                    .scaleEffect(breathe ? 1.06 : 1.0)
                    .opacity(breathe ? 0.55 : 1.0)
                // 头像
                Text(emoji)
                    .font(.system(size: 42))
                    .frame(width: 78, height: 78)
                    .background(DS.Palette.cardSurface)
                    .clipShape(Circle())
                // 在线圆点
                Circle()
                    .fill(online ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.5))
                    .frame(width: 15, height: 15)
                    .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 3))
                    .offset(x: 30, y: 30)
            }
            .frame(width: 96, height: 96)

            Text(name)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
        }
        .onAppear {
            guard online, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .onChange(of: online) {
            if online, !reduceMotion {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { breathe = false }
            }
        }
    }
}

// MARK: - 心跳联结线（两人都在线时跳动）

private struct HeartbeatLink: View {
    let alive: Bool
    let reduceMotion: Bool

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            thread
            Image(systemName: "heart.fill")
                .font(.system(size: alive ? 18 : 15))
                .foregroundStyle(DS.Palette.pink.opacity(alive ? 1 : 0.4))
                .scaleEffect(pulse ? 1.18 : 1.0)
            thread
        }
        .onAppear {
            guard alive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: alive) {
            if alive, !reduceMotion {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { pulse = false }
            }
        }
    }

    private var thread: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [DS.Palette.pink.opacity(alive ? 0.5 : 0.2), DS.Palette.pink.opacity(0.05)],
                    startPoint: .trailing, endPoint: .leading))
            .frame(height: 1.5)
    }
}
