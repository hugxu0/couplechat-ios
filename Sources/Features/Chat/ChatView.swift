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
        ZStack(alignment: .bottom) {
            messageList
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        replyBar
                        aiTypingHint
                        if !mediaPreviewItems.isEmpty {
                            mediaPreviewRow
                        }
                        composer
                    }
                }

            // 表情面板覆盖层（不推动消息布局）
            if showStickerPanel {
                StickerEmojiPanel(
                    store: stickerStore,
                    onEmoji: { draft += $0 },
                    onSendSticker: { sendSticker($0) })
                    .frame(height: 300)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: inputFocused) { _, focused in
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
        .animation(.none, value: draft.isEmpty)
        .animation(.none, value: mediaPreviewItems.isEmpty)
        .animation(DS.Anim.springFast, value: isRecording)
        .animation(DS.Anim.springFast, value: recordingCancelled)
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
        case "sticker":
            return "[表情]"
        case "image":
            return "[图片]"
        case "video":
            return "[视频]"
        case "file":
            return "[文件]"
        default:
            return message.displayText
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let peerAvatar: String
    var myAvatar: String = "🐶"
    var peerAvatarURL: URL? = nil
    var myAvatarURL: URL? = nil
    let groupedWithPrevious: Bool
    let read: Bool
    let canRetry: Bool
    let highlighted: Bool
    var onRetry: () -> Void = {}
    var onMediaTap: () -> Void = {}
    var contextMenuContent: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                avatarBadge(url: peerAvatarURL, emoji: peerAvatar)
                    .opacity(groupedWithPrevious ? 0 : 1)
            }

            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 5) {
                    bubbleContentWithMenu
                    if mine { statusIndicator }
                }
                if let confirm = message.meta?.confirm {
                    ActionConfirmCard(messageId: message.id, confirm: confirm)
                        .frame(maxWidth: 280, alignment: mine ? .trailing : .leading)
                }
                if let search = message.meta?.search, !search.items.isEmpty {
                    SearchCitationsCard(items: search.items)
                        .frame(maxWidth: 280, alignment: mine ? .trailing : .leading)
                }
            }

            if mine {
                avatarBadge(url: myAvatarURL, emoji: myAvatar)
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
        case "sticker":
            stickerBubble
        case "image":
            imageBubble
        case "video":
            videoBubble
        case "voice":
            voiceBubble
        case "file":
            fileBubble
        default:
            let hasReply = message.replyPreview != nil && !(message.replyPreview ?? "").isEmpty
            Text(message.displayText)
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

    /// 贴纸：无气泡底、无阴影、固定小尺寸，跟图片区分开
    private var stickerBubble: some View {
        Group {
            if let url = mediaURL {
                CachedImage(url: url, contentMode: .fit) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Palette.bubbleOther.opacity(0.35))
                }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Palette.bubbleOther.opacity(0.35))
            }
        }
        .frame(width: 116, height: 116)
        .opacity(message.pending ? 0.7 : 1)
    }

    private var imageBubble: some View {
        Group {
            if let url = mediaURL {
                RemoteImageBubble(url: url)
            } else {
                mediaFallback("photo", text: message.pending ? "上传中" : "图片")
                    .frame(width: 180, height: 128)
                    .background(DS.Palette.bubbleOther.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .onTapGesture {
            guard !message.pending else { return }
            onMediaTap()
        }
        .opacity(message.pending ? 0.72 : 1)
    }

    private var videoBubble: some View {
        ZStack {
            if let url = mediaURL {
                VideoThumbnailView(url: url)
                    .frame(width: 220, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                    .fill(DS.Palette.bubbleOther.opacity(0.6))
                    .frame(width: 220, height: 132)
            }
            Circle()
                .fill(.black.opacity(0.42))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
            if message.pending {
                VStack(spacing: 6) {
                    Spacer()
                    Text("视频上传中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.38), in: Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 220, height: 132)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .onTapGesture {
            guard !message.pending else { return }
            onMediaTap()
        }
        .opacity(message.pending ? 0.72 : 1)
    }

    private var voiceBubble: some View {
        Group {
            if let url = mediaURL {
                VoiceBubbleView(url: url, mine: mine)
            } else {
                mediaFallback("mic", text: message.pending ? "上传中" : "语音")
                    .frame(width: 130, height: 20)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
        .opacity(message.pending ? 0.7 : 1)
    }

    private var fileBubble: some View {
        Button {
            guard let mediaURL else { return }
            UIApplication.shared.open(mediaURL)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(mine ? .white : DS.Palette.accent)
                    .frame(width: 34, height: 34)
                    .background(mine ? Color.white.opacity(0.18) : DS.Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                        .lineLimit(1)
                    Text(message.pending ? "上传中" : "点击打开")
                        .font(.system(size: 12))
                        .foregroundStyle(mine ? .white.opacity(0.72) : DS.Palette.textSecondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(width: 228, alignment: .leading)
            .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
            .opacity(message.pending ? 0.7 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(message.pending || mediaURL == nil)
    }

    private var fileTitle: String {
        let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != "[文件]" { return text }
        if let name = mediaURL?.lastPathComponent, !name.isEmpty { return name }
        return "文件"
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

    private var mediaURL: URL? { message.mediaURL }

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
            ProgressView()
                .controlSize(.mini)
                .tint(DS.Palette.textSecondary)
        } else {
            Image(systemName: read ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(read ? DS.Palette.accent : DS.Palette.textSecondary)
        }
    }

    private func avatarBadge(url: URL?, emoji: String) -> some View {
        AvatarBadge(url: url, fallbackEmoji: emoji, size: 36)
    }
}

private struct VoiceBubbleView: View {
    let url: URL
    let mine: Bool

    @State private var player: AVAudioPlayer?
    @State private var delegate: VoicePlaybackDelegate?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private static let barHeights: [CGFloat] = [6, 12, 18, 9, 15, 20, 8, 14, 22, 10, 16, 7, 19, 11, 17, 9, 13, 6]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoading ? "waveform" : (isPlaying ? "pause.fill" : "play.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(mine ? .white : DS.Palette.accent)
                .frame(width: 28, height: 28)
                .background(mine ? Color.white.opacity(0.22) : DS.Palette.accent.opacity(0.15))
                .clipShape(Circle())

            HStack(spacing: 2) {
                ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(mine ? Color.white.opacity(0.7) : DS.Palette.accent.opacity(0.55))
                        .frame(width: 2, height: height)
                }
            }
            .frame(height: 22)

            Text(timeLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(mine ? .white.opacity(0.85) : DS.Palette.textSecondary)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture { togglePlayback() }
        .onDisappear {
            progressTimer?.invalidate()
            player?.stop()
        }
    }

    private var timeLabel: String {
        let value = isPlaying ? max(0, duration - elapsed) : duration
        return String(format: "%d″", max(0, Int(value.rounded())))
    }

    private func togglePlayback() {
        guard !isLoading else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            progressTimer?.invalidate()
            return
        }
        if let player {
            player.play()
            isPlaying = true
            startTimer()
        } else {
            loadAndPlay()
        }
    }

    private func loadAndPlay() {
        isLoading = true
        Task {
            let localURL: URL?
            if url.isFileURL {
                localURL = url
            } else if let (data, _) = try? await URLSession.shared.data(from: url) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                try? data.write(to: tmp)
                localURL = tmp
            } else {
                localURL = nil
            }
            await MainActor.run {
                isLoading = false
                guard let localURL, let p = try? AVAudioPlayer(contentsOf: localURL) else { return }
                let d = VoicePlaybackDelegate { isPlaying = false; elapsed = 0; progressTimer?.invalidate() }
                p.delegate = d
                p.prepareToPlay()
                delegate = d
                player = p
                duration = p.duration
                p.play()
                isPlaying = true
                startTimer()
            }
        }
    }

    private func startTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                elapsed = player?.currentTime ?? 0
            }
        }
    }
}

private final class VoicePlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}

private struct RemoteImageBubble: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                let size = Self.fitSize(for: image.size)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            } else if failed {
                VStack(spacing: 7) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                    Text("图片加载失败")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 180, height: 128)
                .background(DS.Palette.bubbleOther.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            } else {
                ProgressView()
                    .tint(DS.Palette.accent)
                    .frame(width: 180, height: 128)
                    .background(DS.Palette.bubbleOther.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            }
        }
        .shadow(color: DS.Surface.shadow.opacity(image == nil ? 0 : 1), radius: 4, y: 2)
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        // 内存命中立刻出图（重复滚动不再抖动）；否则走缓存的后台下载 + 解码
        if let hit = ImageCache.shared.memoryImage(for: url) {
            image = hit
            return
        }
        failed = false
        if let loaded = await ImageCache.shared.image(for: url) {
            image = loaded
        } else {
            failed = true
        }
    }

    private static func fitSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 220, height: 160)
        }
        let maxWidth: CGFloat = 238
        let maxHeight: CGFloat = 320
        let minSide: CGFloat = 96
        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
        var width = imageSize.width * scale
        var height = imageSize.height * scale
        if min(width, height) < minSide {
            let grow = minSide / min(width, height)
            width *= grow
            height *= grow
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

private struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [.black.opacity(0.16), .black.opacity(0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage).preparingForDisplay()
                ?? UIImage(cgImage: cgImage)
        }.value
        thumbnail = image
    }
}

private struct MediaPagerView: View {
    let messages: [ChatMessage]
    @Binding var selectedId: String?

    @State private var saving = false
    @State private var toast: String?

    private var selection: Binding<String> {
        Binding(
            get: { selectedId ?? messages.first?.id ?? "" },
            set: { selectedId = $0 }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if messages.isEmpty {
                Text("暂无媒体")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                TabView(selection: selection) {
                    ForEach(messages) { message in
                        MediaPage(message: message)
                            .tag(message.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            VStack {
                HStack(spacing: 12) {
                    Button {
                        selectedId = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.42), in: Circle())
                    }

                    Spacer()

                    Text(positionText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.38), in: Capsule())

                    Spacer()

                    Button {
                        saveCurrent()
                    } label: {
                        Group {
                            if saving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.42), in: Circle())
                    }
                    .disabled(saving || currentURL == nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 42)
                }
                .transition(.opacity)
            }
        }
    }

    private var currentMessage: ChatMessage? {
        guard let selectedId else { return messages.first }
        return messages.first { $0.id == selectedId } ?? messages.first
    }

    private var currentURL: URL? { currentMessage?.mediaURL }

    private var positionText: String {
        guard let currentMessage, let index = messages.firstIndex(where: { $0.id == currentMessage.id }) else {
            return "0/0"
        }
        return "\(index + 1)/\(messages.count)"
    }

    private func saveCurrent() {
        guard let currentMessage, let url = currentURL else { return }
        saving = true
        Task {
            let success: Bool
            if currentMessage.type == "video" {
                success = await MediaSaver.saveVideo(from: url)
            } else {
                success = await MediaSaver.saveImage(from: url)
            }
            await MainActor.run {
                saving = false
                showToast(success ? "已保存到相册" : "保存失败")
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(DS.Anim.ease) {
            toast = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard toast == text else { return }
            withAnimation(DS.Anim.ease) {
                toast = nil
            }
        }
    }
}

private struct MediaPage: View {
    let message: ChatMessage

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if message.type == "video", let url = mediaURL {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let url = mediaURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .tint(.white)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        case .failure:
                            failedView
                        @unknown default:
                            failedView
                        }
                    }
                } else {
                    failedView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
    }

    private var mediaURL: URL? { message.mediaURL }

    private var failedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
            Text("加载失败")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.72))
    }
}

private enum MediaSaver {
    static func saveImage(from url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return false }
            await MainActor.run {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
            return true
        } catch {
            return false
        }
    }

    static func saveVideo(from url: URL) async -> Bool {
        do {
            let (source, _) = try await URLSession.shared.download(from: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            await MainActor.run {
                UISaveVideoAtPathToSavedPhotosAlbum(destination.path, nil, nil, nil)
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - 按日期查找

struct DateJumpSheet: View {
    let channel: ChatChannel
    var onJump: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeManager
    @State private var selectedDate = Date()
    @State private var didAppear = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("选择日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(theme.accent.color)
                    .padding(.horizontal, 8)
                    .onChange(of: selectedDate) {
                        guard didAppear else { return }
                        Haptics.selection()
                        onJump(selectedDate)
                        dismiss()
                    }

                Button {
                    Haptics.light()
                    onJump(selectedDate)
                    dismiss()
                } label: {
                    Label("跳转到当天", systemImage: "arrow.down.message.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(theme.accent.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 18)

                Spacer(minLength: 0)
            }
            .navigationTitle("按日期查找")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    didAppear = true
                }
            }
        }
    }
}

// MARK: - 搜索聊天记录

struct ChatSearchSheet: View {
    let channel: ChatChannel
    /// 点击某条结果时回调命中消息，由宿主负责加载上下文并滚动定位
    var onJump: (ChatMessage) -> Void = { _ in }
    /// 非 nil 时在工具栏显示日历入口，用于按日期跳转
    var onJumpDate: ((Date) -> Void)? = nil

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var searching = false
    @State private var searched = false
    @State private var showDateJump = false
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
                if onJumpDate != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            showDateJump = true
                        } label: {
                            Image(systemName: "calendar")
                        }
                    }
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
            .sheet(isPresented: $showDateJump) {
                DateJumpSheet(channel: channel, onJump: { date in
                    onJumpDate?(date)
                    dismiss()
                })
                .presentationDetents([.medium, .large])
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
            Text(highlighted(msg.displayText))
                .font(.system(size: 15))
                .lineLimit(3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            onJump(msg)
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

struct MediaGallerySheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMedia: ChatMessage?
    @State private var fullScreenImage: UIImage?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var mediaMessages: [ChatMessage] {
        store.mediaMessages(for: channel, includeFiles: true)
    }

    var body: some View {
        NavigationStack {
            if mediaMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                    Text("暂无媒体或文件")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("媒体与文件")
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
                .navigationTitle("媒体与文件")
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
        if msg.type == "file" {
            fileThumb(msg)
                .onTapGesture { selectedMedia = msg }
        } else if msg.type == "video", let url = msg.mediaURL {
            ZStack {
                VideoThumbnailView(url: url)
                    .aspectRatio(contentMode: .fill)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: (UIScreen.main.bounds.width - 4) / 3)
            .clipped()
            .onTapGesture { selectedMedia = msg }
        } else if let url = msg.mediaURL {
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

    private func fileThumb(_ msg: ChatMessage) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)
            Text(fileTitle(msg))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
        .background(DS.Palette.innerSurface)
    }

    @ViewBuilder
    private func mediaDetail(_ msg: ChatMessage) -> some View {
        NavigationStack {
            VStack {
                if let url = msg.mediaURL {
                    if msg.type == "file" {
                        VStack(spacing: 14) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 54, weight: .semibold))
                                .foregroundStyle(DS.Palette.accent)
                            Text(fileTitle(msg))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(DS.Palette.textPrimary)
                                .multilineTextAlignment(.center)
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("打开文件", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(DS.Palette.accent, in: Capsule())
                            }
                            .buttonStyle(PressableStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if msg.type == "video" {
                        VideoPlayer(player: AVPlayer(url: url))
                    } else {
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

    private func fileTitle(_ msg: ChatMessage) -> String {
        let text = msg.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != "[文件]" { return text }
        if let name = msg.mediaURL?.lastPathComponent, !name.isEmpty { return name }
        return "文件"
    }
}

// MARK: - 更换壁纸

struct WallpaperPickerSheet: View {
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

// MARK: - AI Actions 确认卡（大橘提议建提醒/备忘，主人确认后才真正写入）

private struct ActionConfirmCard: View {
    @EnvironmentObject private var store: ChatStore
    let messageId: String
    let confirm: ActionConfirm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(confirm.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: item.action.type))
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if confirm.status == "pending" {
                HStack(spacing: 10) {
                    Button {
                        store.confirmAction(messageId: messageId, decision: "confirm")
                    } label: {
                        Text("确认")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(DS.Palette.accent, in: Capsule())
                    }
                    Button {
                        store.confirmAction(messageId: messageId, decision: "cancel")
                    } label: {
                        Text("取消")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(DS.Palette.bubbleOther, in: Capsule())
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: confirm.status == "confirmed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(confirm.status == "confirmed" ? DS.Palette.green : DS.Palette.textSecondary)
                    Text(confirm.status == "confirmed" ? "已确认" : "已取消")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .padding(12)
        .background(DS.Palette.bubbleOther.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Palette.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "add_reminder": return "bell.badge"
        case "add_memo": return "note.text"
        case "complete_reminder": return "checkmark.circle"
        case "delete_reminder": return "trash"
        case "edit_memo": return "pencil.line"
        default: return "pawprint"
        }
    }
}

// MARK: - 联网搜索来源卡片

private struct SearchCitationsCard: View {
    let items: [SearchCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                Text("来源")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.Palette.textSecondary)

            ForEach(items) { item in
                if let url = URL(string: item.url) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DS.Palette.accent)
                                .lineLimit(2)
                            Text(item.url)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(DS.Palette.bubbleOther.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
