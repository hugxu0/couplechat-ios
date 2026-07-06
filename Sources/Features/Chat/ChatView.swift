import SwiftUI

// 聊天会话页：真实数据来自 ChatStore（couple 频道）。

struct ChatView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ChatStore
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] { store.messages }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .background(DS.Palette.bgGradient.ignoresSafeArea())
        .navigationTitle(store.partner?.name ?? "聊天")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(store.partner?.name ?? "聊天")
                        .font(.system(size: 17, weight: .semibold))
                    Text(store.partnerOnline ? "在线" : "离线")
                        .font(.system(size: 11))
                        .foregroundStyle(store.partnerOnline ? DS.Palette.green : DS.Palette.textSecondary)
                }
            }
        }
        // 进会话隐藏底部标签栏，退出（含侧滑返回）恢复
        .onAppear {
            app.chatOpen = true
            store.markRead()
        }
        .onDisappear { app.chatOpen = false }
    }

    // MARK: 消息列表
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        VStack(spacing: 0) {
                            if showTimeSeparator(index) {
                                Text(msg.timeString)
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .padding(.vertical, 14)
                            }
                            if msg.kind == "system" {
                                Text(msg.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .padding(.vertical, 8)
                            } else {
                                MessageBubble(
                                    message: msg,
                                    mine: msg.sender == store.session?.username,
                                    groupedWithPrevious: isGrouped(index),
                                    read: store.partnerHasRead(msg),
                                    onRetry: { store.resend(msg) })
                                .padding(.top, bubbleTopPadding(index))
                            }
                        }
                        .id(msg.id)
                        .onAppear {
                            if index == 0 { store.loadOlder() } // 滚到最早一条 → 翻更早历史
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            // 点消息区空白处收起键盘（simultaneous 不干扰滚动手势）
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            .onChange(of: messages) {
                guard let last = messages.last else { return }
                withAnimation(DS.Anim.message) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // 键盘弹出时跟着滚到底，最新消息不被键盘挡住
            .onChange(of: inputFocused) {
                guard inputFocused, let last = messages.last else { return }
                withAnimation(DS.Anim.ease) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 与上一条间隔超过 8 分钟才显示时间分隔（贴近网页版行为）
    private func showTimeSeparator(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        return messages[index].ts - messages[index - 1].ts > 8 * 60 * 1000
    }

    /// 跟上一条是同一个人 → 算同组（气泡间距更小、头像只显示一次）
    private func isGrouped(_ index: Int) -> Bool {
        guard index > 0, !showTimeSeparator(index) else { return false }
        return messages[index - 1].sender == messages[index].sender
            && messages[index - 1].kind != "system"
    }

    private func bubbleTopPadding(_ index: Int) -> CGFloat {
        guard index > 0, !showTimeSeparator(index) else { return 0 }
        return isGrouped(index) ? DS.Spacing.bubbleGapSame : DS.Spacing.bubbleGapOther
    }

    // MARK: 输入栏（Telegram 式：独立按钮 + 单层输入框，材质统一走 dsGlass）
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            composerIcon("cat")        // 大橘互动
            composerIcon("paperclip")  // 附件（图片/视频/文件以后都收进这里）

            // 单层输入框，表情按钮嵌在框内右侧
            HStack(alignment: .bottom, spacing: 6) {
                TextField("消息", text: $draft, axis: .vertical)
                    .focused($inputFocused)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                Button { } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 21))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))

            // 没文字 → 语音；有文字 → 变成主题色发送按钮（Telegram 的行为）
            Button {
                if draft.isEmpty {
                    Haptics.medium() // 语音留待后续实现
                } else {
                    sendDraft()
                }
            } label: {
                Group {
                    if draft.isEmpty {
                        Image(systemName: "mic")
                            .font(.system(size: 20))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .frame(width: 38, height: 38)
                            .dsGlass(in: Circle())
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(DS.Palette.accent)
                            .clipShape(Circle())
                    }
                }
                .animation(DS.Anim.springFast, value: draft.isEmpty)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func composerIcon(_ name: String) -> some View {
        Button { } label: {
            Image(systemName: name)
                .font(.system(size: 20))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 38, height: 38)
                .dsGlass(in: Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.light()
        draft = ""
        withAnimation(DS.Anim.message) {
            store.sendText(text)
        }
    }
}

// MARK: - 消息气泡
struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let groupedWithPrevious: Bool
    let read: Bool
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                avatar("🐰")
                    .opacity(groupedWithPrevious ? 0 : 1) // 同组连续消息只在第一条显示头像
            }

            HStack(alignment: .bottom, spacing: 5) {
                bubbleContent
                if mine { statusIndicator }
            }

            if mine {
                avatar("🐶")
                    .opacity(groupedWithPrevious ? 0 : 1)
            }

            if !mine { Spacer(minLength: 60) }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: mine ? .bottomTrailing : .bottomLeading)
                .combined(with: .opacity),
            removal: .opacity))
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.type {
        case "image", "sticker", "video":
            // 媒体消息占位：附件功能接通后换成真图
            Text(message.type == "video" ? "[视频]" : "[图片]")
                .font(.system(size: 15))
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(DS.Palette.bubbleOther)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        default:
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
                .opacity(message.pending ? 0.7 : 1)
        }
    }

    /// 我方消息状态：发送中 → 钟；失败 → 红叹号可点重发；送达 → 单勾；已读 → 主题色双勾
    @ViewBuilder
    private var statusIndicator: some View {
        if message.failed {
            Button(action: onRetry) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
            }
        } else if message.pending {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(DS.Palette.textSecondary)
        } else {
            Image(systemName: read ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(read ? DS.Palette.accent : DS.Palette.textSecondary)
        }
    }

    private func avatar(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: 20))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.9))
            .clipShape(Circle())
    }
}
