import SwiftUI

/// 消息列表组件
struct MessageListView: View {
    let channel: ChatChannel
    @Bindable var viewModel: ChatViewModel
    @EnvironmentObject private var store: ChatStore
    
    private var messages: [ChatMessage] { store.messages(for: channel) }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // 加载指示器
                    if store.isLoadingOlder(channel) {
                        ProgressView()
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    } else if !store.connected && store.reachedOldestLocal.contains(channel.rawValue) {
                        Text("已显示所有本地消息")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    } else {
                        // 加载更多哨兵
                        Color.clear
                            .frame(height: 1)
                            .id("loadMoreSentinel")
                            .onAppear {
                                guard messages.count > 0 else { return }
                                viewModel.pendingTopAnchor = messages.first?.id
                                store.loadOlder(channel)
                            }
                    }
                    
                    // 消息列表
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        MessageRow(
                            message: msg,
                            index: index,
                            messages: messages,
                            viewModel: viewModel,
                            channel: channel
                        )
                    }
                    
                    // 底部锚点
                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) {
                guard !viewModel.isJumping else { return }
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: messages.first?.id) { _, _ in
                guard let anchor = viewModel.pendingTopAnchor else { return }
                viewModel.pendingTopAnchor = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.none) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                    viewModel.dismissAllPanels()
                }
            )
        }
    }
    
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }
}

// MARK: - 消息行

private struct MessageRow: View {
    let message: ChatMessage
    let index: Int
    let messages: [ChatMessage]
    @Bindable var viewModel: ChatViewModel
    let channel: ChatChannel
    @EnvironmentObject private var store: ChatStore
    
    private var showTimeSeparator: Bool {
        guard index > 0 else { return true }
        return messages[index].ts - messages[index - 1].ts > 8 * 60 * 1000
    }
    
    private var isGrouped: Bool {
        guard index > 0 else { return false }
        let prev = messages[index - 1]
        return message.sender == prev.sender &&
               message.ts - prev.ts < 120_000 &&
               !showTimeSeparator
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if showTimeSeparator {
                Text(message.timeString)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 14)
            }
            
            if message.kind == "system" {
                SystemMessageView(message: message)
            } else {
                let own = message.sender == store.session?.username
                let withinTwoMin = own && (Date().timeIntervalSince1970 * 1000 - message.ts) < 120_000
                MessageBubble(
                    message: message,
                    mine: own,
                    peerAvatar: nil, // TODO: 传入正确的头像
                    myAvatar: nil,
                    peerAvatarURL: nil,
                    myAvatarURL: nil,
                    groupedWithPrevious: isGrouped,
                    read: store.partnerHasRead(message),
                    canRetry: message.type == "text",
                    highlighted: viewModel.highlightedMessageId == message.id,
                    onRetry: { store.resend(message) },
                    onMediaTap: {
                        viewModel.mediaViewerMessageId = message.id
                    },
                    contextMenuContent: AnyView(contextMenu(own: own, withinTwoMin: withinTwoMin))
                )
                .padding(.top, isGrouped ? 2 : 8)
            }
        }
        .id(message.id)
    }
    
    @ViewBuilder
    private func contextMenu(own: Bool, withinTwoMin: Bool) -> some View {
        if message.type == "text" && !message.text.isEmpty {
            Button {
                UIPasteboard.general.string = message.text
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        
        if withinTwoMin && own {
            Button(role: .destructive) {
                store.recallMessage(message, channel: channel)
            } label: {
                Label("撤回", systemImage: "arrow.uturn.backward")
            }
        }
        
        Button {
            viewModel.setReplyTarget(message)
        } label: {
            Label("回复", systemImage: "arrowshape.turn.up.left")
        }
    }
}

// MARK: - 系统消息

private struct SystemMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        Text(message.text)
            .font(.system(size: 12))
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(DS.Palette.textSecondary.opacity(0.1), in: Capsule())
    }
}
