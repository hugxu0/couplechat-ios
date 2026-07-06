import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// 聊天会话页：真实数据来自 ChatStore，可承载 couple / ai 两个频道。

struct ChatView: View {
    let channel: ChatChannel

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ChatStore
    @State private var draft = ""
    @State private var selectedMedia: PhotosPickerItem?
    @State private var mediaBusy = false
    @FocusState private var inputFocused: Bool

    init(channel: ChatChannel = .couple) {
        self.channel = channel
    }

    private var messages: [ChatMessage] { store.messages(for: channel) }
    private var title: String {
        switch channel {
        case .couple: return store.partner?.name ?? "聊天"
        case .ai: return "大橘"
        }
    }
    private var subtitle: String {
        switch channel {
        case .couple: return store.partnerOnline ? "在线" : "离线"
        case .ai: return store.aiTyping ? "正在输入" : "陪你聊天"
        }
    }
    private var subtitleColor: Color {
        switch channel {
        case .couple: return store.partnerOnline ? DS.Palette.green : DS.Palette.textSecondary
        case .ai: return store.aiTyping ? DS.Palette.green : DS.Palette.textSecondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .background(DS.Palette.bgGradient.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor)
                }
            }
        }
        // 进会话隐藏底部标签栏，退出（含侧滑返回）恢复
        .onAppear {
            app.chatOpen = true
            store.markRead(channel)
        }
        .onDisappear { app.chatOpen = false }
        .onChange(of: selectedMedia) {
            guard let selectedMedia else { return }
            sendMedia(selectedMedia)
        }
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
                                    peerAvatar: channel == .ai ? "🐱" : "🐰",
                                    groupedWithPrevious: isGrouped(index),
                                    read: store.partnerHasRead(msg),
                                    canRetry: msg.type == "text",
                                    onRetry: { store.resend(msg) })
                                .padding(.top, bubbleTopPadding(index))
                            }
                        }
                        .id(msg.id)
                        .onAppear {
                            if index == 0 { store.loadOlder(channel) } // 滚到最早一条 → 翻更早历史
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
            if channel == .couple {
                composerIcon("cat")    // 大橘互动入口后续可改成跳转 AI 频道
            }
            mediaPicker

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

    private var mediaPicker: some View {
        PhotosPicker(
            selection: $selectedMedia,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()) {
                Image(systemName: mediaBusy ? "hourglass" : "paperclip")
                    .font(.system(size: 20))
                    .foregroundStyle(mediaBusy ? DS.Palette.textSecondary : DS.Palette.accent)
                    .frame(width: 38, height: 38)
                    .dsGlass(in: Circle())
            }
            .buttonStyle(PressableStyle())
            .disabled(mediaBusy)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.light()
        draft = ""
        withAnimation(DS.Anim.message) {
            store.sendText(text, channel: channel)
        }
    }

    private func sendMedia(_ item: PhotosPickerItem) {
        mediaBusy = true
        Task {
            defer {
                Task { @MainActor in
                    mediaBusy = false
                    selectedMedia = nil
                }
            }

            guard let prepared = try? await prepareMedia(item) else {
                await MainActor.run { Haptics.medium() }
                return
            }

            await MainActor.run {
                Haptics.light()
                withAnimation(DS.Anim.message) {
                    store.sendMedia(
                        data: prepared.data,
                        mimeType: prepared.mimeType,
                        preferredType: prepared.messageType,
                        localPreviewURL: nil,
                        channel: channel)
                }
            }
        }
    }

    private func prepareMedia(_ item: PhotosPickerItem) async throws -> PreparedMedia {
        let contentTypes = item.supportedContentTypes
        let isVideo = contentTypes.contains { $0.conforms(to: .movie) }
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw NSError(domain: "media", code: 1)
        }

        if isVideo {
            let mimeType = contentTypes.contains(.quickTimeMovie) ? "video/quicktime" : "video/mp4"
            return PreparedMedia(data: data, mimeType: mimeType, messageType: "video")
        }

        if contentTypes.contains(.png) {
            return PreparedMedia(data: data, mimeType: "image/png", messageType: "image")
        }
        if contentTypes.contains(.gif) {
            return PreparedMedia(data: data, mimeType: "image/gif", messageType: "image")
        }
        if contentTypes.contains(.webP) {
            return PreparedMedia(data: data, mimeType: "image/webp", messageType: "image")
        }
        if contentTypes.contains(.jpeg) {
            return PreparedMedia(data: data, mimeType: "image/jpeg", messageType: "image")
        }

        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.86) else {
            throw NSError(domain: "media", code: 2)
        }
        return PreparedMedia(data: jpeg, mimeType: "image/jpeg", messageType: "image")
    }
}

private struct PreparedMedia {
    let data: Data
    let mimeType: String
    let messageType: String
}

// MARK: - 消息气泡
struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let peerAvatar: String
    let groupedWithPrevious: Bool
    let read: Bool
    let canRetry: Bool
    var onRetry: () -> Void = {}

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                avatar(peerAvatar)
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
        case "image", "sticker":
            imageBubble
        case "video":
            videoBubble
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

    private var imageBubble: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                .fill(mine ? DS.Palette.accent.opacity(0.18) : Color.white.opacity(0.92))

            if let url = mediaURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(DS.Palette.accent)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        mediaFallback("photo", text: "图片加载失败")
                    @unknown default:
                        mediaFallback("photo", text: "图片")
                    }
                }
            } else {
                mediaFallback("photo", text: message.pending ? "上传中" : "图片")
            }
        }
        .frame(width: 210, height: 156)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
        .opacity(message.pending ? 0.72 : 1)
    }

    private var videoBubble: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                .fill(mine ? DS.Palette.accent : DS.Palette.bubbleOther)

            VStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(mine ? .white : DS.Palette.accent)
                Text(message.pending ? "视频上传中" : "视频")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
            }
        }
        .frame(width: 210, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
        .opacity(message.pending ? 0.72 : 1)
    }

    @ViewBuilder
    private func mediaFallback(_ systemName: String, text: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 28))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(DS.Palette.textSecondary)
    }

    private var mediaURL: URL? {
        guard let url = message.url else { return nil }
        return URL(string: url)
    }

    /// 我方消息状态：发送中 → 钟；失败 → 红叹号可点重发；送达 → 单勾；已读 → 主题色双勾
    @ViewBuilder
    private var statusIndicator: some View {
        if message.failed {
            if canRetry {
                Button(action: onRetry) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                }
            } else {
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
