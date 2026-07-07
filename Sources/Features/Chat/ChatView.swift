import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// 聊天会话页：真实数据来自 ChatStore，可承载 couple / ai 两个频道。

struct ChatView: View {
    let channel: ChatChannel

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @State private var selectedMedia: PhotosPickerItem?
    @State private var mediaBusy = false
    @State private var showSearch = false
    @State private var showWallpaperPicker = false
    @State private var replyTarget: ChatMessage?
    @State private var showMedia = false
    @State private var scrollToMessageId: String?
    @State private var highlightedMessageId: String?
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
        if !store.connected {
            return store.lastConnectionError ?? "未连接"
        }
        switch channel {
        case .couple: return store.partnerOnline ? "在线" : "离线"
        case .ai: return store.aiTyping ? "正在输入" : "陪你聊天"
        }
    }
    private var subtitleColor: Color {
        if !store.connected { return .red }
        switch channel {
        case .couple: return store.partnerOnline ? DS.Palette.green : DS.Palette.textSecondary
        case .ai: return store.aiTyping ? DS.Palette.green : DS.Palette.textSecondary
        }
    }
    private var displayedWallpaper: WallpaperChoice {
        if colorScheme == .dark && !theme.hasCustomWallpaper(for: channel) {
            return .night
        }
        return theme.wallpaper(for: channel)
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    replyBar
                    composer
                }
            }
        .background(
            ZStack {
                displayedWallpaper.gradient(dark: colorScheme == .dark)
                if let img = theme.customWallpaperImage(for: channel) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                }
                displayedWallpaper.patternOverlay
            }
            .ignoresSafeArea()
        )
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showSearch = true
                    } label: {
                        Label("搜索聊天记录", systemImage: "magnifyingglass")
                    }
                    Button {
                        showMedia = true
                    } label: {
                        Label("媒体内容", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showWallpaperPicker = true
                    } label: {
                        Label("更换壁纸", systemImage: "photo.on.rectangle.angled")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchSheet(channel: channel, scrollToMessageId: $scrollToMessageId)
        }
        .sheet(isPresented: $showMedia) {
            MediaGallerySheet(channel: channel)
        }
        .sheet(isPresented: $showWallpaperPicker) {
            WallpaperPickerSheet(channel: channel)
                .presentationDetents([.medium, .large])
        }
        // 搜索结果跳转到原文
        .onChange(of: scrollToMessageId) { _, _ in
            guard scrollToMessageId != nil else { return }
            showSearch = false
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
                                systemMessage(msg)
                            } else {
                                let own = msg.sender == store.session?.username
                                let withinTwoMin = own && (Date().timeIntervalSince1970 * 1000 - msg.ts) < 120_000
                                MessageBubble(
                                    message: msg,
                                    mine: own,
                                    peerAvatar: peerAvatar,
                                    groupedWithPrevious: isGrouped(index),
                                    read: store.partnerHasRead(msg),
                                    canRetry: msg.type == "text",
                                    highlighted: highlightedMessageId == msg.id,
                                    onRetry: { store.resend(msg) },
                                    contextMenuContent: AnyView(messageContextMenu(msg, own: own, withinTwoMin: withinTwoMin)))
                                .padding(.top, bubbleTopPadding(index))
                            }
                        }
                        .id(msg.id)
                        .onAppear {
                            if index == 0 { store.loadOlder(channel) }
                        }
                    }
                    // 底部锚点：所有需要贴底的时候 scrollTo 到这里
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
            // 点击空白处用 UIKit 标准方式收起键盘，跟系统键盘动画统一
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            )
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: messages.count) { scrollToBottom(proxy) }
            // 键盘弹/收：输入栏由系统避让键盘，这里只用同一动画同步贴底滚动。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                withAnimation(keyboardAnimation(from: note)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                withAnimation(keyboardAnimation(from: note)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: scrollToMessageId) { _, targetId in
                guard let targetId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(DS.Anim.ease) {
                        proxy.scrollTo(targetId, anchor: .center)
                        highlightedMessageId = targetId
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        guard highlightedMessageId == targetId else { return }
                        withAnimation(DS.Anim.ease) {
                            highlightedMessageId = nil
                        }
                        if scrollToMessageId == targetId {
                            scrollToMessageId = nil
                        }
                    }
                }
            }
        }
    }

    /// 滚到底部锚点；延迟一帧让 LazyVStack 渲染稳定
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        DispatchQueue.main.async {
            withAnimation(animated ? DS.Anim.message : nil) {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
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

    private var peerAvatar: String {
        if channel == .ai { return "🐱" }
        return store.partner?.avatar ?? AccountPresentation.avatar(for: store.partner?.username ?? "si")
    }

    // MARK: 系统消息（撤回消息加重新编辑）
    @ViewBuilder
    private func systemMessage(_ msg: ChatMessage) -> some View {
        HStack(spacing: 4) {
            Text(msg.text)
                .font(.system(size: 12))
                .foregroundStyle(DS.Palette.textSecondary)
            if msg.sender == store.session?.username,
               let recalledText = msg.recalledText, !recalledText.isEmpty {
                Button {
                    draft = recalledText
                    inputFocused = true
                } label: {
                    Text("重新编辑")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Palette.accent)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: 长按菜单
    @ViewBuilder
    private func messageContextMenu(_ msg: ChatMessage, own: Bool, withinTwoMin: Bool) -> some View {

        if msg.type == "text" {
            Button {
                UIPasteboard.general.string = msg.text
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }

        Button {
            replyTarget = msg
            inputFocused = true
        } label: {
            Label("引用", systemImage: "arrowshape.turn.up.left")
        }

        if withinTwoMin && !msg.pending && !msg.failed {
            Button(role: .destructive) {
                store.recallMessage(msg, channel: channel)
            } label: {
                Label("撤回", systemImage: "trash")
            }
        }
    }

    // MARK: 回复引用条
    @ViewBuilder
    private var replyBar: some View {
        if let target = replyTarget {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(DS.Palette.accent)
                    .frame(width: 3, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                        .lineLimit(1)
                    Text(target.text)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation(DS.Anim.springFast) {
                        replyTarget = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
        let target = replyTarget
        draft = ""
        replyTarget = nil
        let replyId = target?.id
        let previewText: String?
        if let target {
            previewText = replyPreview(for: target)
        } else {
            previewText = nil
        }
        withAnimation(DS.Anim.message) {
            store.sendText(text, channel: channel, replyTo: replyId, replyPreview: previewText)
        }
    }

    private func replyPreview(for message: ChatMessage) -> String {
        let body: String
        switch message.type {
        case "image", "sticker":
            body = "[图片]"
        case "video":
            body = "[视频]"
        default:
            body = message.text
        }
        return "\(message.senderName): \(body)"
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

private func keyboardAnimation(from note: Notification) -> Animation {
    let info = note.userInfo ?? [:]
    let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
        ?? UIView.AnimationCurve.easeInOut.rawValue
    let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut

    guard duration > 0 else { return .linear(duration: 0.01) }

    switch curve {
    case .easeInOut:
        return .timingCurve(0.42, 0, 0.58, 1, duration: duration)
    case .easeIn:
        return .timingCurve(0.42, 0, 1, 1, duration: duration)
    case .easeOut:
        return .timingCurve(0, 0, 0.58, 1, duration: duration)
    case .linear:
        return .linear(duration: duration)
    @unknown default:
        return .easeOut(duration: duration)
    }
}

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }

    func messageSearchHighlight(_ highlighted: Bool) -> some View {
        self
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: DS.Radius.bubble + 5, style: .continuous)
                        .stroke(DS.Palette.accent.opacity(0.9), lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.bubble + 5, style: .continuous)
                                .fill(DS.Palette.accent.opacity(0.14))
                        )
                        .padding(-5)
                }
            }
            .shadow(color: highlighted ? DS.Palette.accent.opacity(0.28) : .clear, radius: 12, y: 2)
    }
}

// MARK: - 消息气泡
private struct MessageContextPreview: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 5) {
                if let preview = message.replyPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(mine ? .white.opacity(0.74) : DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Text(summary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 230, alignment: .leading)
            .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            if !mine { Spacer(minLength: 24) }
        }
        .padding(.horizontal, 12)
    }

    private var summary: String {
        switch message.type {
        case "image", "sticker":
            return "[图片]"
        case "video":
            return "[视频]"
        default:
            return message.text
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let peerAvatar: String
    let groupedWithPrevious: Bool
    let read: Bool
    let canRetry: Bool
    let highlighted: Bool
    var onRetry: () -> Void = {}
    var contextMenuContent: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                avatar(peerAvatar)
                    .opacity(groupedWithPrevious ? 0 : 1)
            }

            HStack(alignment: .bottom, spacing: 5) {
                bubbleContentWithMenu
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
    private var bubbleContentWithMenu: some View {
        let hasReply = message.replyPreview != nil && !(message.replyPreview ?? "").isEmpty

        let content = Group {
            if hasReply {
                VStack(alignment: .leading, spacing: 3) {
                    replyPreviewLabel
                    messageCore
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
                .opacity(message.pending ? 0.7 : 1)
            } else {
                messageCore
            }
        }

        let decorated = content
            .messageSearchHighlight(highlighted)

        if let menu = contextMenuContent {
            decorated.contextMenu {
                menu
            } preview: {
                MessageContextPreview(message: message, mine: mine)
            }
        } else {
            decorated
        }
    }

    @ViewBuilder
    private var messageCore: some View {
        switch message.type {
        case "image", "sticker":
            imageBubble
        case "video":
            videoBubble
        default:
            let hasReply = message.replyPreview != nil && !(message.replyPreview ?? "").isEmpty
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                .if(!hasReply) {
                    $0.padding(.horizontal, 15)
                      .padding(.vertical, 10)
                      .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                      .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                      .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
                      .opacity(message.pending ? 0.7 : 1)
                }
        }
    }

    private var replyPreviewLabel: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(.white.opacity(mine ? 0.45 : 0.35))
                .frame(width: 2.5, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            Text(message.replyPreview ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mine ? .white.opacity(0.75) : DS.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var imageBubble: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                .fill(mine ? DS.Palette.accent.opacity(0.18) : DS.Palette.bubbleOther)

            if let url = mediaURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(DS.Palette.accent)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(2)
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
        .frame(width: 220, height: 220)
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
            .background(DS.Palette.bubbleOther)
            .clipShape(Circle())
    }
}

// MARK: - 搜索聊天记录

private struct ChatSearchSheet: View {
    let channel: ChatChannel
    @Binding var scrollToMessageId: String?

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var searching = false
    @State private var searched = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    emptyState
                } else {
                    resultList
                }
            }
            .navigationTitle("搜索聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索消息内容")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) {
                if query.isEmpty {
                    results = []
                    searched = false
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if searching {
                ProgressView()
            } else if searched {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
                Text("没有找到「\(query)」相关的消息")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                Text("输入关键词，回车搜索")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(results) { msg in
                    resultRow(msg)
                }
            } header: {
                Text("共 \(results.count) 条结果")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func resultRow(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(msg.senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.accent)
                Spacer()
                Text(Self.dateTime(msg.ts))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text(highlighted(msg.text))
                .font(.system(size: 15))
                .lineLimit(3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            scrollToMessageId = msg.id
            dismiss()
        }
    }

    /// 关键词命中部分标主题色加粗
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = attributed.range(of: q, options: .caseInsensitive) else { return attributed }
        attributed[range].foregroundColor = DS.Palette.accent
        attributed[range].font = .system(size: 15, weight: .bold)
        return attributed
    }

    private static func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            let found = await store.searchMessages(q, channel: channel)
            await MainActor.run {
                searching = false
                searched = true
                withAnimation(DS.Anim.ease) {
                    // 服务端按时间倒序返回，直接展示（最新的在最上面）
                    results = found.sorted { $0.ts > $1.ts }
                }
            }
        }
    }
}

// MARK: - 媒体内容浏览

private struct MediaGallerySheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMedia: ChatMessage?
    @State private var fullScreenImage: UIImage?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var mediaMessages: [ChatMessage] {
        store.messages(for: channel).filter {
            ($0.type == "image" || $0.type == "video" || $0.type == "sticker")
                && $0.kind == "user" && !$0.pending
        }.reversed()
    }

    var body: some View {
        NavigationStack {
            if mediaMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                    Text("暂无图片或视频")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("媒体内容")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(mediaMessages) { msg in
                            mediaThumb(msg)
                        }
                    }
                }
                .navigationTitle("媒体内容")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
                .sheet(item: $selectedMedia) { msg in
                    mediaDetail(msg)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaThumb(_ msg: ChatMessage) -> some View {
        if let urlStr = msg.url, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
                        .clipped()
                case .failure:
                    fallbackThumb(msg)
                case .empty:
                    Color.gray.opacity(0.15)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
                        .overlay(ProgressView().tint(DS.Palette.accent))
                @unknown default:
                    fallbackThumb(msg)
                }
            }
            .onTapGesture { selectedMedia = msg }
        } else {
            fallbackThumb(msg)
                .onTapGesture { selectedMedia = msg }
        }
    }

    @ViewBuilder
    private func fallbackThumb(_ msg: ChatMessage) -> some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: msg.type == "video" ? "play.rectangle" : "photo")
                .font(.system(size: 24))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
    }

    @ViewBuilder
    private func mediaDetail(_ msg: ChatMessage) -> some View {
        NavigationStack {
            VStack {
                if let urlStr = msg.url, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 40))
                                Text("加载失败")
                            }
                            .foregroundStyle(DS.Palette.textSecondary)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
                Spacer()

                HStack(spacing: 12) {
                    Text(msg.senderName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(Self.dateTime(msg.ts))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .padding(.bottom, 20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { selectedMedia = nil }
                }
            }
        }
    }

    private static func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }
}

// MARK: - 更换壁纸

private struct WallpaperPickerSheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var customPickerItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(WallpaperChoice.allCases) { choice in
                        wallpaperTile(choice)
                    }
                    customTile
                }
                .padding(DS.Spacing.page)
            }
            .navigationTitle("聊天壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: customPickerItem) {
                guard let item = customPickerItem else { return }
                loadCustomImage(item)
            }
        }
    }

    private func wallpaperTile(_ choice: WallpaperChoice) -> some View {
        let hasCustom = theme.hasCustomWallpaper(for: channel)
        let selected = !hasCustom && theme.wallpaper(for: channel) == choice
        return Button {
            Haptics.selection()
            theme.removeCustomWallpaper(for: channel)
            withAnimation(DS.Anim.spring) {
                theme.setWallpaper(choice, for: channel)
            }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(choice.previewGradient)
                    .frame(height: 120)
                    .overlay { choice.patternOverlay }
                    .overlay(
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 42, height: 12)
                            Capsule().fill(DS.Palette.accent.opacity(0.9)).frame(width: 34, height: 12)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(selected ? DS.Palette.accent : .clear, lineWidth: 3)
                    )
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Palette.accent)
                    }
                    Text(choice.name)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textSecondary)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var customTile: some View {
        let isCustom = theme.hasCustomWallpaper(for: channel)
        return PhotosPicker(selection: $customPickerItem, matching: .images) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isCustom ? AnyShapeStyle(DS.Palette.accent.opacity(0.12)) : AnyShapeStyle(Color.gray.opacity(0.1)))
                    .frame(height: 120)
                    .overlay {
                        if isCustom, let img = theme.customWallpaperImage(for: channel) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: 120)
                                .clipped()
                        } else {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isCustom ? DS.Palette.accent : .clear, lineWidth: 3)
                    )
                HStack(spacing: 4) {
                    if isCustom {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Palette.accent)
                    }
                    Text(isCustom ? "已自定义" : "自定义")
                        .font(.system(size: 13, weight: isCustom ? .semibold : .regular))
                        .foregroundStyle(isCustom ? DS.Palette.accent : DS.Palette.textSecondary)
                }

                if isCustom {
                    Button(role: .destructive) {
                        theme.removeCustomWallpaper(for: channel)
                    } label: {
                        Text("移除")
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func loadCustomImage(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            await MainActor.run {
                theme.setCustomWallpaper(imageData: jpeg, for: channel)
                customPickerItem = nil
            }
        }
    }
}
