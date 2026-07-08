import SwiftUI
import PhotosUI

/// 聊天页面 - 重构后的版本
/// 使用分层架构：背景层 / 消息层 / 输入层 / 面板覆盖层
struct ChatView: View {
    let channel: ChatChannel
    
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var viewModel = ChatViewModel()
    @ObservedObject private var stickerStore = StickerStore.shared
    
    init(channel: ChatChannel = .couple) {
        self.channel = channel
    }
    
    // MARK: - 计算属性
    
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
    
    // MARK: - Body
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景层
            wallpaperBackground
            
            // 消息层
            MessageListView(channel: channel, viewModel: viewModel)
            
            // 输入层 + 面板覆盖层
            VStack(spacing: 0) {
                // 回复栏
                ReplyBar(
                    message: viewModel.replyTarget,
                    onClose: { viewModel.clearReplyTarget() }
                )
                
                // AI 打字提示
                AiTypingHint(
                    isTyping: store.aiTyping,
                    isReplying: store.aiReplying
                )
                
                // 输入栏
                ComposerView(channel: channel, viewModel: viewModel)
            }
            
            // 表情面板覆盖层（覆盖在输入栏上方，不推动布局）
            StickerPanelOverlay(
                isVisible: viewModel.showStickerPanel,
                onEmoji: { viewModel.draft += $0 },
                onSendSticker: { sendSticker($0) },
                stickerStore: stickerStore
            )
            .allowsHitTesting(viewModel.showStickerPanel)
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
                        partnerAvatar: nil,
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
        .sheet(isPresented: $viewModel.showMedia) {
            MediaGallerySheet(channel: channel)
        }
        .sheet(isPresented: $viewModel.showWallpaperPicker) {
            WallpaperPickerSheet(channel: channel)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.mediaViewerMessageId != nil },
            set: { if !$0 { viewModel.mediaViewerMessageId = nil } }
        )) {
            let mediaMessages = Array(store.mediaMessages(for: channel, includeFiles: false).reversed())
            MediaPagerView(messages: mediaMessages, selectedId: $viewModel.mediaViewerMessageId)
        }
        .fileImporter(
            isPresented: $viewModel.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            // TODO: 处理文件导入
        }
        .alert("需要麦克风权限", isPresented: $viewModel.showMicPermissionAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请在系统设置中允许访问麦克风，才能发送语音消息")
        }
        .onAppear {
            app.pushSubpage()
            store.ensureLocalMessages(channel)
            store.markRead(channel)
        }
        .onDisappear {
            app.popSubpage()
        }
        .onChange(of: viewModel.selectedMediaItems) {
            viewModel.loadMediaPreviewItems()
        }
        .onChange(of: viewModel.isInputFocused) { _, focused in
            if focused {
                viewModel.dismissAllPanels()
            }
        }
    }
    
    // MARK: - 背景
    
    private var wallpaperBackground: some View {
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
    }
    
    // MARK: - 发送贴纸
    
    private func sendSticker(_ sticker: Sticker) {
        Haptics.light()
        store.sendSticker(url: sticker.url, channel: channel)
    }
    
    // MARK: - 跳转
    
    private func jumpToMessage(_ message: ChatMessage) {
        if store.ensureMessageLoaded(message, channel: channel) {
            viewModel.scrollToMessageId = message.id
        }
    }
    
    private func jumpToDate(_ date: Date) {
        if let message = store.ensureDateLoaded(date, channel: channel) {
            viewModel.scrollToMessageId = message.id
        }
    }
}
