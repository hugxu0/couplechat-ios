import SwiftUI

// 聊天会话页：消息列表 + 输入栏。
// 消息发送目前只是本地追加（假数据），重点是先把气泡样式、
// 入场动画、滚动行为这些「手感」打磨出来。

struct Message: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let mine: Bool
    let time: String
    var showTime: Bool = false // 是否在这条消息上方显示时间分隔
}

struct ChatView: View {
    @State private var messages: [Message] = [
        Message(text: "那我们看一会", mine: true, time: "02:58"),
        Message(text: "嗯嗯", mine: false, time: "02:59"),
        Message(text: "开始了宝宝", mine: true, time: "03:00", showTime: true),
        Message(text: "嗯嗯", mine: false, time: "03:06", showTime: true),
        Message(text: "看一会睡觉了", mine: false, time: "03:06"),
        Message(text: "心跳好快", mine: false, time: "03:07"),
        Message(text: "好", mine: true, time: "03:08"),
        Message(text: "晚安老公", mine: false, time: "03:18", showTime: true),
        Message(text: "晚安老婆", mine: true, time: "03:18"),
    ]
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .background(DS.Palette.bgGradient.ignoresSafeArea())
        .navigationTitle("小偲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DS.Palette.textPrimary)
                }
            }
        }
    }

    // MARK: 消息列表
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        VStack(spacing: 0) {
                            if msg.showTime {
                                Text(msg.time)
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .padding(.vertical, 14)
                            }
                            MessageBubble(message: msg, groupedWithPrevious: isGrouped(index))
                                .padding(.top, bubbleTopPadding(index))
                        }
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages) {
                guard let last = messages.last else { return }
                withAnimation(DS.Anim.message) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 跟上一条是同一个人 → 算同组（气泡间距更小、圆角贴合）
    private func isGrouped(_ index: Int) -> Bool {
        guard index > 0 else { return false }
        return messages[index - 1].mine == messages[index].mine && !messages[index].showTime
    }

    private func bubbleTopPadding(_ index: Int) -> CGFloat {
        guard index > 0, !messages[index].showTime else { return 0 }
        return isGrouped(index) ? DS.Spacing.bubbleGapSame : DS.Spacing.bubbleGapOther
    }

    // MARK: 输入栏
    private var composer: some View {
        HStack(spacing: 10) {
            composerIcon("cat")
            composerIcon("photo")

            TextField("", text: $draft, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous))

            composerIcon("face.smiling")

            // 有文字 → 发送按钮；没文字 → 语音按钮（带切换动画）
            Button {
                sendDraft()
            } label: {
                Image(systemName: draft.isEmpty ? "mic.fill" : "arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(DS.Palette.accent)
                    .clipShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, DS.Spacing.page)
        .padding(.vertical, 8)
        .background(Color.white.opacity(DS.Surface.tabBarOpacity))
    }

    private func composerIcon(_ name: String) -> some View {
        Button { } label: {
            Image(systemName: name)
                .font(.system(size: 20))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.85))
                .clipShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.light()
        draft = ""
        withAnimation(DS.Anim.message) {
            messages.append(Message(text: text, mine: true, time: "现在"))
        }
    }
}

// MARK: - 消息气泡
struct MessageBubble: View {
    let message: Message
    let groupedWithPrevious: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.mine { Spacer(minLength: 60) }

            if !message.mine {
                avatar("🐰")
                    .opacity(groupedWithPrevious ? 0 : 1) // 同组连续消息只在第一条显示头像
            }

            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(message.mine ? .white : DS.Palette.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(message.mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                .shadow(color: DS.Surface.shadow, radius: 4, y: 2)

            if message.mine {
                avatar("🐶")
                    .opacity(groupedWithPrevious ? 0 : 1)
            }

            if !message.mine { Spacer(minLength: 60) }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: message.mine ? .bottomTrailing : .bottomLeading)
                .combined(with: .opacity),
            removal: .opacity))
    }

    private func avatar(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: 20))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.9))
            .clipShape(Circle())
    }
}
