import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AVKit

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
    @State private var showFileImporter = false
    @State private var showWallpaperPicker = false
    @State private var replyTarget: ChatMessage?
    @State private var showMedia = false
    @State private var scrollToMessageId: String?
    @State private var highlightedMessageId: String?
    @State private var pendingTopAnchor: String?
    @State private var isJumping = false
    @State private var mediaViewerMessageId: String?
    @State private var isRecording = false
    @State private var recordingCancelled = false
    @State private var recordingElapsed: TimeInterval = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var recordingPulse = false
    @State private var recordingTimer: Timer?
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var recordingStartDate: Date?
    @State private var showMicPermissionAlert = false
    @State private var showStickerPanel = false
    @State private var showAttachmentTray = false
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var mediaPreviewItems: [MediaPreviewItem] = []
    @ObservedObject private var stickerStore = StickerStore.shared
    @FocusState private var inputFocused: Bool
    private static let cancelDragThreshold: CGFloat = -70
    private static let composerButtonSize: CGFloat = 44

    init(channel: ChatChannel = .couple) {
        self.channel = channel
    }

    private var messages: [ChatMessage] { store.messages(for: channel) }
    private var mediaMessages: [ChatMessage] {
        // 贴纸不进大图浏览 / 媒体库，只算真实图片和视频
        Array(store.mediaMessages(for: channel, includeFiles: false).reversed())
    }
    private var title: String {
        switch channel {
        case .couple: return store.partnerDisplayName(fallback: "聊天")
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
                    aiTypingHint
                    if !mediaPreviewItems.isEmpty {
                        mediaPreviewRow
                    }
                    composer
                    if showStickerPanel {
                        StickerEmojiPanel(
                            store: stickerStore,
                            onEmoji: { draft += $0 },
                            onSendSticker: { sendSticker($0) })
                            .frame(height: 300)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .onChange(of: inputFocused) { _, focused in
                // 弹出键盘时收起表情面板和附件面板，三者不并存
                if focused {
                    if showStickerPanel || showAttachmentTray {
                        withAnimation(DS.Anim.springFast) {
                            showStickerPanel = false
                            showAttachmentTray = false
                        }
                    }
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    ChatDetailSettingsView(
                        channel: channel,
                        partnerName: title,
                        partnerAvatar: peerAvatar,
                        partnerOnline: store.partnerOnline,
                        onJumpToMessage: { jumpToMessage($0) },
                        onJumpToDate: { jumpToDate($0) }
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showMedia) {
            MediaGallerySheet(channel: channel)
        }
        .sheet(isPresented: $showWallpaperPicker) {
            WallpaperPickerSheet(channel: channel)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: Binding(
            get: { mediaViewerMessageId != nil },
            set: { if !$0 { mediaViewerMessageId = nil } }
        )) {
            MediaPagerView(messages: mediaMessages, selectedId: $mediaViewerMessageId)
        }
        // 进会话隐藏底部标签栏，退出（含侧滑返回）恢复
        .onAppear {
            app.pushSubpage()
            // 兜底：内存里没消息时立刻从本地库补，保证进来就能看到历史
            store.ensureLocalMessages(channel)
            store.markRead(channel)
        }
        .onDisappear { app.popSubpage() }
        .onChange(of: selectedMediaItems) {
            loadMediaPreviewItems()
        }
        .alert("需要麦克风权限", isPresented: $showMicPermissionAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许访问麦克风，才能发送语音消息")
        }
    }

    // MARK: 消息列表
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
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
                        // 加载更多哨兵：滚到顶部自动触发
                        Color.clear
                            .frame(height: 1)
                            .id("loadMoreSentinel")
                            .onAppear {
                                guard messages.count > 0 else { return }
                                pendingTopAnchor = messages.first?.id
                                store.loadOlder(channel)
                            }
                    }
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
                                    myAvatar: myAvatarEmoji,
                                    peerAvatarURL: peerAvatarURL,
                                    myAvatarURL: myAvatarURL,
                                    groupedWithPrevious: isGrouped(index),
                                    read: store.partnerHasRead(msg),
                                    canRetry: msg.type == "text",
                                    highlighted: highlightedMessageId == msg.id,
                                    onRetry: { store.resend(msg) },
                                    onMediaTap: {
                                        mediaViewerMessageId = msg.id
                                    },
                                    contextMenuContent: AnyView(messageContextMenu(msg, own: own, withinTwoMin: withinTwoMin)))
                                .padding(.top, bubbleTopPadding(index))
                            }
                        }
                        .id(msg.id)
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
                    if showStickerPanel || showAttachmentTray {
                        withAnimation(DS.Anim.springFast) {
                            showStickerPanel = false
                            showAttachmentTray = false
                        }
                    }
                }
            )
            // 初始定位交给 .defaultScrollAnchor(.bottom)，这里只在消息数变化时补贴底，
            // 避免进页面时多一次 scrollTo 造成的入场卡顿。
            .onChange(of: messages.last?.id) {
                guard !isJumping else { return }
                scrollToBottom(proxy, animated: true)
            }
            // 顶部插入更早消息后，把视口锚回插入前的第一条消息，避免画面跳动
            .onChange(of: messages.first?.id) { _, _ in
                guard let anchor = pendingTopAnchor else { return }
                pendingTopAnchor = nil
                // 等两帧让 LazyVStack 完成布局，再定位到原来的首条消息
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.none) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
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
            .onChange(of: showStickerPanel) {
                withAnimation(DS.Anim.springFast) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: showAttachmentTray) {
                withAnimation(DS.Anim.springFast) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: scrollToMessageId) { _, targetId in
                guard let targetId else { return }
                isJumping = true
                // 等搜索 sheet 收起、新插入的消息完成布局后再定位（0.4s 覆盖 sheet 关闭动画）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // 定位滚动不加动画，避免对刚整体替换、未布局过的 LazyVStack 做动画插值
                    proxy.scrollTo(targetId, anchor: .center)
                    withAnimation(DS.Anim.ease) {
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
                        isJumping = false
                    }
                }
            }
        }
    }

    /// 搜索结果跳转：先确保命中消息已加载进列表（可能是很老的历史），再触发滚动定位
    private func jumpToMessage(_ message: ChatMessage) {
        store.ensureMessageLoaded(message, channel: channel)
        scrollToMessageId = message.id
    }

    private func jumpToDate(_ date: Date) {
        guard let target = store.ensureDateLoaded(date, channel: channel) else { return }
        scrollToMessageId = target.id
    }

    /// 滚到底部锚点；延迟一帧让 LazyVStack 渲染稳定
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
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

    private var peerAvatarURL: URL? {
        channel == .ai ? nil : store.avatarURL(for: store.partner?.username)
    }

    private var myAvatarEmoji: String {
        AccountPresentation.avatar(for: store.session?.username ?? "xu")
    }

    private var myAvatarURL: URL? {
        store.avatarURL(for: store.session?.username)
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
                UIPasteboard.general.string = msg.displayText
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
                    Text(target.displayText)
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

    @ViewBuilder
    private var aiTypingHint: some View {
        if channel == .ai && (store.aiTyping || store.aiReplying) {
            HStack(spacing: 8) {
                typingDots
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var typingDots: some View {
        HStack(spacing: 5) {
            Circle().frame(width: 7, height: 7)
                .scaleEffect(store.aiTyping || store.aiReplying ? 1.0 : 0.7)
                .opacity(typingDotOpacity(0))
                .animation(typingDotAnimation(0), value: store.aiTyping || store.aiReplying)
            Circle().frame(width: 7, height: 7)
                .scaleEffect(store.aiTyping || store.aiReplying ? 1.0 : 0.7)
                .opacity(typingDotOpacity(1))
                .animation(typingDotAnimation(1), value: store.aiTyping || store.aiReplying)
            Circle().frame(width: 7, height: 7)
                .scaleEffect(store.aiTyping || store.aiReplying ? 1.0 : 0.7)
                .opacity(typingDotOpacity(2))
                .animation(typingDotAnimation(2), value: store.aiTyping || store.aiReplying)
        }
        .foregroundStyle(DS.Palette.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.bubbleOther, in: Capsule())
    }

    private func typingDotOpacity(_ index: Int) -> Double {
        guard store.aiTyping || store.aiReplying else { return 0.55 }
        let phase = (Date().timeIntervalSinceReferenceDate * 3.4) + Double(index) * 0.35
        let value = (sin(phase) + 1) / 2
        return 0.35 + value * 0.65
    }

    private func typingDotAnimation(_ index: Int) -> Animation {
        .easeInOut(duration: 0.6 + Double(index) * 0.08).repeatForever(autoreverses: true)
    }

    // MARK: 输入栏（Telegram 式：附件嵌入输入框内，与表情按钮对称；麦克风按住说话）
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isRecording {
                recordingBar
            } else {
                if channel == .couple {
                    catButton
                }
                messageBox
            }
            micButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // 单层输入框：附件按钮嵌在左侧，表情按钮嵌在右侧，对称布局，整体高度与两侧圆形按钮对齐
    private var messageBox: some View {
        HStack(alignment: .center, spacing: 8) {
            mediaPicker
            TextField("消息", text: $draft, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .font(.system(size: 17))
                .multilineTextAlignment(.leading)
            Button {
                Haptics.light()
                toggleStickerPanel()
            } label: {
                Image(systemName: showStickerPanel ? "keyboard" : "face.smiling")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(showStickerPanel ? DS.Palette.accent : DS.Palette.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 13)
        .frame(minHeight: Self.composerButtonSize)
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))
    }

    private var mediaPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mediaPreviewItems) { item in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            withAnimation(DS.Anim.springFast) {
                                mediaPreviewItems.removeAll { $0.id == item.id }
                                selectedMediaItems.removeAll { $0 == item.item }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, DS.Palette.textSecondary.opacity(0.5))
                        }
                        .offset(x: 3, y: -3)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 8)
        }
        .frame(height: 64)
    }

    // 录音中：替换输入框，展示时长 + 左滑取消提示
    private var recordingBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(recordingPulse ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recordingPulse)
            Text(recordingTimeLabel)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("滑动取消")
                    .font(.system(size: 14))
            }
            .foregroundStyle(recordingCancelled ? .red : DS.Palette.textSecondary)
            .offset(x: min(0, dragTranslation * 0.4))
        }
        .padding(.horizontal, 16)
        .frame(height: Self.composerButtonSize)
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))
        .onAppear { recordingPulse = true }
        .onDisappear { recordingPulse = false }
    }

    private var recordingTimeLabel: String {
        let total = Int(recordingElapsed.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // 没文字 → 按住说话（空心主题色线条，跟左侧小猫按钮对称的玻璃底）；
    // 有文字 → 主题色发送按钮；录音中 → 实心提示态
    private var micButton: some View {
        Group {
            if isRecording {
                Image(systemName: recordingCancelled ? "trash.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .background(recordingCancelled ? Color.red : DS.Palette.accent)
                    .clipShape(Circle())
                    .scaleEffect(recordingCancelled ? 1.12 : 1.0)
            } else if !mediaPreviewItems.isEmpty {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .background(DS.Palette.accent)
                    .clipShape(Circle())
            } else if draft.isEmpty {
                Image(systemName: "mic")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .dsGlassInteractive(in: Circle())
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .background(DS.Palette.accent)
                    .clipShape(Circle())
            }
        }
        .animation(DS.Anim.springFast, value: draft.isEmpty)
        .animation(DS.Anim.springFast, value: isRecording)
        .animation(DS.Anim.springFast, value: recordingCancelled)
        .animation(DS.Anim.springFast, value: mediaPreviewItems.isEmpty)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard draft.isEmpty && mediaPreviewItems.isEmpty else { return }
                    if !isRecording {
                        beginRecording()
                    }
                    guard isRecording else { return }
                    dragTranslation = value.translation.width
                    let shouldCancel = dragTranslation < Self.cancelDragThreshold
                    if shouldCancel != recordingCancelled {
                        recordingCancelled = shouldCancel
                        Haptics.medium()
                    }
                }
                .onEnded { _ in
                    if !mediaPreviewItems.isEmpty {
                        sendMediaItems()
                        return
                    }
                    if !draft.isEmpty {
                        sendDraft()
                        return
                    }
                    guard isRecording else { return }
                    finishRecording(cancelled: recordingCancelled)
                }
        )
    }

    /// 小猫按钮：主题色线性猫头，点一下召唤大橘
    private var catButton: some View {
        Button {
            summonDaju()
        } label: {
            CatHeadIcon()
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 23, height: 23)
                .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                .dsGlassInteractive(in: Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private var mediaPicker: some View {
        PhotosPicker(
            selection: $selectedMediaItems,
            maxSelectionCount: 9,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        ) {
            Image(systemName: mediaBusy ? "hourglass" : "paperclip")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(mediaBusy ? DS.Palette.textSecondary.opacity(0.6) : DS.Palette.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PressableStyle())
        .disabled(mediaBusy)
    }

    // MARK: 录音（Telegram 式按住说话：抬手发送，左滑取消）

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingCancelled = false
        dragTranslation = 0
        recordingElapsed = 0
        Haptics.light()

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecorder()
        case .denied:
            isRecording = false
            showMicPermissionAlert = true
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                await MainActor.run {
                    guard isRecording else { return }
                    if granted {
                        startRecorder()
                    } else {
                        isRecording = false
                        showMicPermissionAlert = true
                    }
                }
            }
        @unknown default:
            isRecording = false
        }
    }

    private func startRecorder() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            isRecording = false
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            isRecording = false
            return
        }
        recorder.record()
        audioRecorder = recorder
        recordingURL = url
        recordingStartDate = Date()

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                recordingElapsed = Date().timeIntervalSince(recordingStartDate ?? Date())
            }
        }
    }

    private func finishRecording(cancelled: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        let duration = recordingElapsed
        let url = recordingURL
        audioRecorder?.stop()
        audioRecorder = nil
        recordingURL = nil
        isRecording = false
        recordingCancelled = false
        dragTranslation = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard !cancelled, duration >= 1.0, let url else {
            if let url { try? FileManager.default.removeItem(at: url) }
            if !cancelled { Haptics.medium() }
            return
        }
        Haptics.light()
        sendVoice(url: url)
    }

    private func sendVoice(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        store.sendMedia(data: data, mimeType: "audio/m4a", preferredType: "voice", localPreviewURL: url, channel: channel)
    }

    /// 猫猫按钮：在公共聊天里召唤大橘（服务端识别 @大橘 触发词才会插话），不跳转私聊
    private func summonDaju() {
        Haptics.light()
        if !draft.contains("@大橘") {
            draft = draft.isEmpty ? "@大橘 " : "@大橘 " + draft
        }
        inputFocused = true
    }

    private func toggleStickerPanel() {
        withAnimation(DS.Anim.springFast) {
            if showStickerPanel {
                showStickerPanel = false
            } else {
                inputFocused = false
                showStickerPanel = true
                showAttachmentTray = false
            }
        }
    }

    private func sendSticker(_ sticker: Sticker) {
        Haptics.light()
        store.sendSticker(url: sticker.url, channel: channel)
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
        store.sendText(text, channel: channel, replyTo: replyId, replyPreview: previewText)
    }

    private func replyPreview(for message: ChatMessage) -> String {
        let body: String
        switch message.type {
        case "sticker":
            body = "[表情]"
        case "image":
            body = "[图片]"
        case "video":
            body = "[视频]"
        case "file":
            body = "[文件]"
        default:
            body = message.displayText
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
                store.sendMedia(
                    data: prepared.data,
                    mimeType: prepared.mimeType,
                    preferredType: prepared.messageType,
                    localPreviewURL: nil,
                    channel: channel)
            }
        }
    }

    private func sendFile(_ url: URL) {
        mediaBusy = true
        Task {
            defer {
                Task { @MainActor in mediaBusy = false }
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else {
                await MainActor.run { Haptics.medium() }
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)
            let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
            let name = url.lastPathComponent
            await MainActor.run {
                Haptics.light()
                store.sendMedia(
                    data: data,
                    mimeType: mimeType,
                    preferredType: "file",
                    localPreviewURL: nil,
                    channel: channel,
                    displayText: name)
            }
        }
    }

    private func loadMediaPreviewItems() {
        let items = selectedMediaItems
        guard !items.isEmpty else {
            withAnimation(DS.Anim.springFast) {
                mediaPreviewItems = []
            }
            return
        }

        mediaBusy = true
        Task {
            var previews: [MediaPreviewItem] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }
                let id = UUID().uuidString
                previews.append(MediaPreviewItem(id: id, image: image, item: item))
            }

            await MainActor.run {
                withAnimation(DS.Anim.springFast) {
                    mediaPreviewItems = previews
                }
                mediaBusy = false
            }
        }
    }

    private func sendMediaItems() {
        let items = mediaPreviewItems
        guard !items.isEmpty else { return }

        mediaBusy = true
        withAnimation(DS.Anim.springFast) {
            mediaPreviewItems = []
            selectedMediaItems = []
        }

        Task {
            for item in items {
                guard let prepared = try? await prepareMedia(item.item) else {
                    continue
                }
                await MainActor.run {
                    Haptics.light()
                    store.sendMedia(
                        data: prepared.data,
                        mimeType: prepared.mimeType,
                        preferredType: prepared.messageType,
                        localPreviewURL: nil,
                        channel: channel)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            await MainActor.run {
                mediaBusy = false
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

private struct MediaPreviewItem: Identifiable {
    let id: String
    let image: UIImage
    let item: PhotosPickerItem
}

struct CatHeadIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.24, y: h * 0.43))
        path.addLine(to: CGPoint(x: w * 0.20, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.39, y: h * 0.29))
        path.addQuadCurve(to: CGPoint(x: w * 0.61, y: h * 0.29), control: CGPoint(x: w * 0.50, y: h * 0.22))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.43))
        path.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.86), control: CGPoint(x: w * 0.82, y: h * 0.74))
        path.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.43), control: CGPoint(x: w * 0.18, y: h * 0.74))

        path.move(to: CGPoint(x: w * 0.38, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.54))
        path.move(to: CGPoint(x: w * 0.62, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.54))
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
        path.addQuadCurve(to: CGPoint(x: w * 0.43, y: h * 0.67), control: CGPoint(x: w * 0.47, y: h * 0.64))
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
        path.addQuadCurve(to: CGPoint(x: w * 0.57, y: h * 0.67), control: CGPoint(x: w * 0.53, y: h * 0.64))

        return path
    }
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









// MARK: - 按日期查找


// MARK: - 搜索聊天记录


// MARK: - 媒体内容浏览


// MARK: - 更换壁纸


// MARK: - AI Actions 确认卡（大橘提议建提醒/备忘，主人确认后才真正写入）


// MARK: - 联网搜索来源卡片


