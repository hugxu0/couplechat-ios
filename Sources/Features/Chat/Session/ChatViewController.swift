import AVFoundation
import Combine
import PhotosUI
import UIKit
import UniformTypeIdentifiers

enum PhotoPickerPurpose {
    case messageMedia
    case sticker(groupId: String)
}

@MainActor
final class ChatViewController: UIViewController {
    let channel: ChatChannel
    var store: ChatStore
    var messageStore: MessageStore { store.messageStore }
    var theme: ThemeManager

    let composer = ChatComposerView()
    let mediaViewerCoordinator = ChatMediaViewerCoordinator()
    let voiceTranscriptRepository = VoiceTranscriptRepository()
    var timelineController: ChatTimelineController!
    var collectionView: UICollectionView!
    let bottomStack = UIStackView()
    let panelContainer = UIView()
    let jumpToBottomBackground = ChatGlassView(cornerRadius: 21)
    let jumpToBottomButton = UIButton(type: .system)
    let bottomRefreshIndicator = UIActivityIndicatorView(style: .medium)
    var jumpToBottomWidthConstraint: NSLayoutConstraint!
    var stickerPanel: ChatStickerPanelView?

    var composerHeightConstraint: NSLayoutConstraint!
    var panelHeightConstraint: NSLayoutConstraint!
    var bottomConstraint: NSLayoutConstraint!
    let inputDockSpacing: CGFloat = 8
    var keyboardOverlap: CGFloat = 0
    var lastVisibleKeyboardOverlap: CGFloat = 300
    /// 键盘动画会逐帧改变时间线可视高度。动画期间需要固定变化开始前的
    /// “是否贴底”意图，避免首帧几何变化把它误判为已离底。
    var keyboardTransitionMaintainsLatest: Bool?
    var keyboardTransitionGeneration = 0
    var keyboardLayoutAnimationActive = false
    var bottomDockUsesScreenBottom = false
    var topOverlayInset: CGFloat = 96
    var composerUsesLightContent = false
    var wallpaperAppearance: WallpaperAppearance
    var usesDarkChatSurface = false
    var timelineUsesLightContent = false
    var appliedAccent: AccentChoice?

    var cancellables: Set<AnyCancellable> = []
    var inputState: ChatInputState = .idle
    var activeJumpID: UUID?
    var isHistoryRefreshing = false
    var isNewerRefreshing = false
    /// Combine 的时间线更新可能在 loadNewerAsync 返回后才投递；保留一次
    /// “这是翻页追加”标记，避免它被实时消息状态机误判。
    var suppressesNextPaginationStoreChange = false
    var lastRenderedMessageID: String?
    var replyTarget: ChatMessage?
    var pendingMedia: [ChatPendingMedia] = []
    var photoPickerPurpose: PhotoPickerPurpose = .messageMedia
    var isChatVisible = false
    var hasCompletedEntryBootstrap = false
    var entryBootstrapTask: Task<Void, Never>?
    var jumpTask: Task<Void, Never>?
    var filePreviewTask: Task<Void, Never>?
    var filePreviewSource: ChatFilePreviewSource?

    var voicePlayer: AVAudioPlayer?
    var voicePlaybackTimer: Timer?
    var voicePlaybackLoadTask: Task<Void, Never>?
    var loadingVoiceMessageID: String?
    var playingVoiceMessageID: String?
    var playingVoiceProgress: CGFloat = 0

    var isRecording = false
    var recordingCancelled = false
    var recordingElapsed: TimeInterval = 0
    var recordingTimer: Timer?
    var audioRecorder: AVAudioRecorder?
    var recordingURL: URL?
    var recordingStartDate: Date?
    var recordingRequestID: UUID?

    var stickToLatestAfterNextReload: Bool {
        get { timelineController?.stickToLatestAfterNextReload ?? false }
        set { timelineController?.stickToLatestAfterNextReload = newValue }
    }

    init(
        channel: ChatChannel,
        store: ChatStore,
        theme: ThemeManager,
        composerUsesLightContent: Bool,
        wallpaperAppearance: WallpaperAppearance,
        usesDarkChatSurface: Bool,
        timelineUsesLightContent: Bool
    ) {
        self.channel = channel
        self.store = store
        self.theme = theme
        self.composerUsesLightContent = composerUsesLightContent
        self.wallpaperAppearance = wallpaperAppearance
        self.usesDarkChatSurface = usesDarkChatSurface
        self.timelineUsesLightContent = timelineUsesLightContent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        recordingRequestID = nil
        recordingTimer?.invalidate()
        audioRecorder?.stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        voicePlayer?.pause()
        voicePlaybackLoadTask?.cancel()
        voicePlaybackTimer?.invalidate()
        entryBootstrapTask?.cancel()
        jumpTask?.cancel()
        filePreviewTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildTimeline()
        buildBottomDock()
        configureKeyboardObservers()
        bindStore()
        composer.delegate = self
        composer.applyTheme(theme, usesLightContent: composerUsesLightContent)
        applyAccentColor()
        installStickerPanel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(messageWasDeleted(_:)),
            name: MessageStore.messageDeletedNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(persistentSyncDidChange(_:)),
            name: .persistentSyncChanged,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionWasInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance())
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance())
        collectionView.alpha = 0
        beginEntryBootstrap()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyInputLayout(duration: 0, curve: .curveEaseOut)
        guard hasCompletedEntryBootstrap else {
            collectionView.alpha = 0
            return
        }
        timelineController.scheduleInitialPositioning()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isChatVisible = true
        store.setChatVisible(channel, visible: true)
        applyInputLayout(duration: 0, curve: .curveEaseOut)
        timelineController.scheduleInitialPositioning()
        DispatchQueue.main.async { [weak self] in self?.reportDisplayedMessagesAsRead() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isChatVisible = false
        store.setChatVisible(channel, visible: false)
        cancelRecordingForInterruption()
    }

    @objc private func appDidBecomeActive() {
        reportDisplayedMessagesAsRead()
    }

    @objc private func appDidEnterBackground() {
        cancelRecordingForInterruption()
    }

    func cancelRecordingForInterruption() {
        guard isRecording || recordingRequestID != nil || audioRecorder != nil else { return }
        inputState = .idle
        finishRecording(cancelled: true)
    }

    var isForegroundWindowActive: Bool {
        viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    @objc private func messageWasDeleted(_ notification: Notification) {
        guard let id = notification.userInfo?["messageId"] as? String else { return }
        mediaViewerCoordinator.dismissIfShowing(messageId: id)
        if playingVoiceMessageID == id { stopVoicePlayback() }
        if replyTarget?.id == id { clearReplyTarget() }
    }

    func reportDisplayedMessagesAsRead() {
        guard isChatVisible,
              isForegroundWindowActive else { return }
        let timestamp = timelineController.displayedMessages()
            .filter { !$0.pending && !$0.failed }
            .map(\.ts)
            .max()
        if let timestamp { store.markRead(channel, through: timestamp) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        timelineController.invalidateLayoutIfNeeded()
        if !keyboardLayoutAnimationActive {
            applyInputLayout(duration: 0, curve: .curveEaseOut)
        }
        timelineController.scheduleInitialPositioning()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let styleChanged = previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
        let contentSizeChanged = previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        if contentSizeChanged {
            timelineController.invalidateAppearance()
            applyInputLayout(duration: 0, curve: .curveEaseOut)
        }
        guard styleChanged else { return }
        wallpaperAppearance = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        let wallpaper = theme.wallpaper(for: channel, appearance: wallpaperAppearance)
        let surfaceLuminance = theme.customWallpaperLuminance(
            for: channel,
            appearance: wallpaperAppearance,
            region: .wholeChat
        ) ?? wallpaper.fallbackSurfaceLuminance(for: wallpaperAppearance)
        let surfaceTone = ChatSurfaceTone(luminance: surfaceLuminance).usesLightContent
        usesDarkChatSurface = surfaceTone
        timelineUsesLightContent = surfaceTone
        composerUsesLightContent = surfaceTone
        composer.applyTheme(theme, usesLightContent: composerUsesLightContent)
        stickerPanel?.applyTheme(
            accentColor: theme.accent.uiColor,
            usesLightContent: composerUsesLightContent)
        timelineController.updatePresentation(makeTimelinePresentation())
        timelineController.invalidateAppearance()
        applyInputLayout(duration: 0, curve: .curveEaseOut)
    }

    func updateEnvironment(
        store: ChatStore,
        theme: ThemeManager,
        topOverlayInset: CGFloat,
        composerUsesLightContent: Bool,
        wallpaperAppearance: WallpaperAppearance,
        usesDarkChatSurface: Bool,
        timelineUsesLightContent: Bool
    ) {
        let storeChanged = self.store !== store
        let themeChanged = self.theme !== theme
        let composerToneChanged = self.composerUsesLightContent != composerUsesLightContent
        let wallpaperAppearanceChanged = self.wallpaperAppearance != wallpaperAppearance
        let surfaceChanged = self.usesDarkChatSurface != usesDarkChatSurface
        let timelineChanged = self.timelineUsesLightContent != timelineUsesLightContent
        self.store = store
        self.theme = theme
        self.wallpaperAppearance = wallpaperAppearance
        self.composerUsesLightContent = composerUsesLightContent
        self.usesDarkChatSurface = usesDarkChatSurface
        self.timelineUsesLightContent = timelineUsesLightContent
        if themeChanged || composerToneChanged || wallpaperAppearanceChanged || appliedAccent != theme.accent {
            composer.applyTheme(theme, usesLightContent: self.composerUsesLightContent)
            stickerPanel?.applyTheme(
                accentColor: theme.accent.uiColor,
                usesLightContent: self.composerUsesLightContent)
            applyAccentColor()
        }
        if surfaceChanged || timelineChanged, collectionView != nil {
            timelineController.updatePresentation(makeTimelinePresentation())
            timelineController.invalidateAppearance()
        }
        setTopOverlayInset(topOverlayInset)
        if storeChanged {
            bindStore()
            reloadTimeline(animated: false)
        }
    }

    func setTopOverlayInset(_ inset: CGFloat) {
        let clamped = max(72, ceil(inset))
        guard abs(topOverlayInset - clamped) > 0.5 else { return }
        topOverlayInset = clamped
        applyInputLayout(duration: 0, curve: .curveEaseOut)
    }

    func performJump(_ command: ChatSessionJumpCommand) {
        guard activeJumpID != command.id else { return }
        activeJumpID = command.id
        entryBootstrapTask?.cancel()
        hasCompletedEntryBootstrap = true
        collectionView.alpha = 1
        jumpTask?.cancel()
        // 在任何异步读取开始前就关闭所有贴底收尾；否则 store 更新先到达时，
        // 旧的 followLatest completion 仍可能覆盖搜索定位。
        timelineController.beginHistoricalJump()
        switch command.action {
        case .message(let message):
            jumpTask = Task { [weak self] in
                guard let self else { return }
                _ = await store.ensureMessageLoaded(message, channel: channel)
                guard !Task.isCancelled, activeJumpID == command.id else { return }
                completeJump(to: message)
            }
        case .date(let date):
            jumpTask = Task { @MainActor [weak self] in
                guard let self,
                      let target = await store.ensureDateLoaded(date, channel: channel) else { return }
                guard !Task.isCancelled, activeJumpID == command.id else { return }
                completeJump(to: target)
            }
        }
    }

    func completeJump(to target: ChatMessage) {
        timelineController.beginHistoricalJump()
        reloadTimeline(animated: false)
        view.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.timelineController.scrollToMessage(id: target.id, highlighted: true)
            self?.updateJumpToBottomVisibility(animated: true)
        }
    }

    /// 新控制器只执行一次：先恢复真实的最新消息窗口，再完成布局和贴底，最后
    /// 才显示列表。这样搜索留下的历史切片不会污染下次进入，也看不到二次校正。
    func beginEntryBootstrap() {
        entryBootstrapTask?.cancel()
        entryBootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await store.restoreLatestMessages(channel)
            guard !Task.isCancelled else { return }

            timelineController.completeFollowingLatest()
            timelineController.browsingHistoricalWindow = false
            reloadTimeline(animated: false, preservingWindowState: true)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            applyInputLayout(duration: 0, curve: .curveEaseOut, forceBottom: true)

            hasCompletedEntryBootstrap = true
            if isChatVisible {
                // 冷启动时最新窗口可能在 viewDidAppear 之后才恢复完成；再扫描一次
                // 未读互动，保证离开聊天期间收到的最后一个效果不会漏掉。
                store.setChatVisible(channel, visible: true)
            }
            timelineController.scheduleInitialPositioning()
            timelineController.scrollToBottom(animated: false)
            timelineController.clearNewMessagesBelow()
            collectionView.alpha = 1
            updateJumpToBottomVisibility(animated: false)
        }
    }

    func buildTimeline() {
        timelineController = ChatTimelineController(presentation: makeTimelinePresentation())
        timelineController.delegate = self
        collectionView = timelineController.collectionView
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCollectionTap(_:)))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
    }

    func buildBottomDock() {
        bottomStack.axis = .vertical
        bottomStack.spacing = 0
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.backgroundColor = .clear
        bottomStack.isOpaque = false
        view.addSubview(bottomStack)
        composer.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.backgroundColor = .clear
        panelContainer.isHidden = true
        bottomStack.addArrangedSubview(composer)
        bottomStack.addArrangedSubview(panelContainer)
        buildJumpToBottomButton()

        composerHeightConstraint = composer.heightAnchor.constraint(equalToConstant: composer.preferredHeight)
        composerHeightConstraint.isActive = true
        composer.heightDidChange = { [weak self] height in
            guard let self else { return }
            composerHeightConstraint.constant = height
            applyInputLayout(duration: 0.18, curve: .curveEaseOut, forceBottom: composer.textView.isFirstResponder)
        }
        panelHeightConstraint = panelContainer.heightAnchor.constraint(equalToConstant: 0)
        panelHeightConstraint.isActive = true
        bottomConstraint = bottomStack.bottomAnchor.constraint(
            equalTo: view.bottomAnchor,
            constant: -(inputDockSpacing + max(view.safeAreaInsets.bottom, keyboardOverlap)))
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 时间线的真实可视底边截止在输入区上方。输入区仍保持透明玻璃外观，
            // 但最后一条消息不再依赖动态 bottomInset 猜测键盘和输入栏遮挡高度。
            collectionView.bottomAnchor.constraint(
                equalTo: bottomStack.topAnchor,
                constant: -inputDockSpacing),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])
    }

    func buildJumpToBottomButton() {
        jumpToBottomBackground.translatesAutoresizingMaskIntoConstraints = false
        jumpToBottomBackground.alpha = 0
        jumpToBottomBackground.isHidden = true
        jumpToBottomBackground.update(cornerRadius: 21)
        jumpToBottomBackground.clipsToBounds = true
        view.addSubview(jumpToBottomBackground)
        bottomRefreshIndicator.translatesAutoresizingMaskIntoConstraints = false
        bottomRefreshIndicator.hidesWhenStopped = true
        view.addSubview(bottomRefreshIndicator)
        jumpToBottomButton.backgroundColor = .clear
        jumpToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        jumpToBottomButton.titleLabel?.numberOfLines = 1
        jumpToBottomButton.titleLabel?.lineBreakMode = .byClipping
        jumpToBottomWidthConstraint = jumpToBottomBackground.widthAnchor.constraint(equalToConstant: 42)
        jumpToBottomButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.timelineController.clearNewMessagesBelow()
            self.updateJumpToBottomVisibility(animated: true)
            Task {
                await self.store.restoreLatestMessages(self.channel)
                self.stickToLatestAfterNextReload = false
                self.reloadTimeline(animated: false, preservingWindowState: true)
                self.timelineController.returnToLatest(animated: true)
                self.updateJumpToBottomVisibility(animated: true)
            }
        }, for: .touchUpInside)
        jumpToBottomBackground.addSubview(jumpToBottomButton)
        NSLayoutConstraint.activate([
            jumpToBottomWidthConstraint,
            jumpToBottomBackground.heightAnchor.constraint(equalToConstant: 42),
            jumpToBottomBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            jumpToBottomBackground.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -12),
            bottomRefreshIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomRefreshIndicator.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -14),
            jumpToBottomButton.leadingAnchor.constraint(equalTo: jumpToBottomBackground.leadingAnchor),
            jumpToBottomButton.trailingAnchor.constraint(equalTo: jumpToBottomBackground.trailingAnchor),
            jumpToBottomButton.topAnchor.constraint(equalTo: jumpToBottomBackground.topAnchor),
            jumpToBottomButton.bottomAnchor.constraint(equalTo: jumpToBottomBackground.bottomAnchor),
        ])
    }

    func applyAccentColor() {
        appliedAccent = theme.accent
        jumpToBottomButton.tintColor = theme.accent.uiColor
        if var configuration = jumpToBottomButton.configuration {
            configuration.baseForegroundColor = theme.accent.uiColor
            jumpToBottomButton.configuration = configuration
        }
        bottomRefreshIndicator.color = theme.accent.uiColor
    }

    func makeTimelinePresentation() -> ChatTimelineController.Presentation {
        ChatTimelineController.Presentation(
            currentUsername: store.session?.username,
            counterpartName: channel == .ai ? "大橘" : store.partnerDisplayName(fallback: "TA"),
            myAvatar: store.avatarText(for: store.session?.username ?? "xu"),
            myAvatarURL: store.avatarURL(for: store.session?.username),
            accentColor: theme.accent.uiColor,
            usesDarkIncomingBubble: usesDarkChatSurface,
            timelineUsesLightContent: timelineUsesLightContent,
            playingVoiceMessageID: playingVoiceMessageID,
            playingVoiceProgress: playingVoiceProgress,
            avatarText: { [weak store] username in store?.avatarText(for: username) ?? "" },
            avatarURL: { [weak store] username in store?.avatarURL(for: username) },
            partnerHasRead: { [weak store] message in store?.partnerHasRead(message) ?? false },
            canReeditRecall: { [weak store] messageId in
                store?.messageStore.hasRecallDraft(messageId: messageId) ?? false
            })
    }
}
