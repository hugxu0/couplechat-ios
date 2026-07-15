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
    let jumpToBottomBackground = ChatGlassView(style: .systemThinMaterial, cornerRadius: 21)
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
    var currentListBottomInset: CGFloat = 0
    var topOverlayInset: CGFloat = 96
    var composerUsesLightContent = false
    var dynamicallySamplesComposerTone = false
    var lastComposerSampleFrame: CGRect = .null
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
    var initialLatestCorrectionPending = false

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
        dynamicallySamplesComposerTone: Bool,
        usesDarkChatSurface: Bool,
        timelineUsesLightContent: Bool
    ) {
        self.channel = channel
        self.store = store
        self.theme = theme
        self.composerUsesLightContent = composerUsesLightContent
        self.dynamicallySamplesComposerTone = dynamicallySamplesComposerTone
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
        reloadTimeline(animated: false)
        Task { [weak self] in
            guard let self else { return }
            await store.ensureLocalMessages(channel)
            reloadTimeline(animated: false)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 先在页面真正显示前完成 bottom inset 与初始贴底，避免用户看到
        // 输入栏出现后列表再向上/向下挪动。
        initialLatestCorrectionPending = true
        applyInputLayout(duration: 0, curve: .curveEaseOut)
        timelineController.scheduleInitialPositioning()
        correctInitialLatestPositionIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isChatVisible = true
        applyInputLayout(duration: 0, curve: .curveEaseOut)
        timelineController.scheduleInitialPositioning()
        correctInitialLatestPositionIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.reportDisplayedMessagesAsRead() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isChatVisible = false
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
        applyInputLayout(duration: 0, curve: .curveEaseOut)
        refreshComposerSurfaceTone()
        timelineController.scheduleInitialPositioning()
        correctInitialLatestPositionIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        if !theme.hasCustomWallpaper(for: channel) {
            let dark = traitCollection.userInterfaceStyle == .dark
            usesDarkChatSurface = dark
            timelineUsesLightContent = dark
        }
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
        dynamicallySamplesComposerTone: Bool,
        usesDarkChatSurface: Bool,
        timelineUsesLightContent: Bool
    ) {
        let storeChanged = self.store !== store
        let themeChanged = self.theme !== theme
        let composerToneChanged = self.composerUsesLightContent != composerUsesLightContent
        let dynamicToneChanged = self.dynamicallySamplesComposerTone != dynamicallySamplesComposerTone
        let surfaceChanged = self.usesDarkChatSurface != usesDarkChatSurface
        let timelineChanged = self.timelineUsesLightContent != timelineUsesLightContent
        self.store = store
        self.theme = theme
        self.dynamicallySamplesComposerTone = dynamicallySamplesComposerTone
        if !dynamicallySamplesComposerTone || dynamicToneChanged {
            self.composerUsesLightContent = composerUsesLightContent
        }
        self.usesDarkChatSurface = usesDarkChatSurface
        self.timelineUsesLightContent = timelineUsesLightContent
        if themeChanged || composerToneChanged || dynamicToneChanged || appliedAccent != theme.accent {
            composer.applyTheme(theme, usesLightContent: self.composerUsesLightContent)
            stickerPanel?.applyTheme(
                accentColor: theme.accent.uiColor,
                usesLightContent: self.composerUsesLightContent)
            applyAccentColor()
        }
        if dynamicallySamplesComposerTone, isViewLoaded {
            refreshComposerSurfaceTone(force: true)
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
        switch command.action {
        case .message(let message):
            Task { [weak self] in
                guard let self else { return }
                _ = await store.ensureMessageLoaded(message, channel: channel)
                completeJump(to: message)
            }
        case .date(let date):
            Task { @MainActor [weak self] in
                guard let self,
                      let target = await store.ensureDateLoaded(date, channel: channel) else { return }
                completeJump(to: target)
            }
        }
    }

    func completeJump(to target: ChatMessage) {
        timelineController.beginHistoricalJump()
        initialLatestCorrectionPending = false
        reloadTimeline(animated: false)
        view.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.timelineController.scrollToMessage(id: target.id, highlighted: true)
            self?.updateJumpToBottomVisibility(animated: true)
        }
    }

    /// 输入栏是浮在列表上方的，首次进入页面时再做一次“贴底”校正，
    /// 确保 composer 的最终高度已经计入 bottom inset，最后一条消息不会被遮住。
    func correctInitialLatestPositionIfNeeded() {
        guard initialLatestCorrectionPending,
              timelineController.hasInitialPosition,
              isNearLatestWindow(),
              viewIfLoaded?.window != nil,
              !collectionView.isTracking,
              !collectionView.isDragging,
              !collectionView.isDecelerating else { return }
        let apply = { [weak self] in
            guard let self,
                  self.initialLatestCorrectionPending,
                  self.isNearLatestWindow(),
                  self.viewIfLoaded?.window != nil,
                  !self.collectionView.isTracking,
                  !self.collectionView.isDragging,
                  !self.collectionView.isDecelerating else { return }
            self.initialLatestCorrectionPending = false
            self.timelineController.completeFollowingLatest()
            UIView.performWithoutAnimation {
                self.collectionView.layer.removeAllAnimations()
                self.applyInputLayout(duration: 0, curve: .curveEaseOut)
                self.timelineController.scrollToBottom(animated: false)
                self.updateJumpToBottomVisibility(animated: false)
            }
        }
        // 首次进入时在 viewDidAppear 之前同步完成；已经可见的页面才延后一帧，
        // 但仍使用 performWithoutAnimation，避免用户看到贴底过程。
        if isChatVisible { DispatchQueue.main.async { apply() } }
        else { apply() }
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
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -inputDockSpacing)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
        ])
    }

    func buildJumpToBottomButton() {
        jumpToBottomBackground.translatesAutoresizingMaskIntoConstraints = false
        jumpToBottomBackground.alpha = 0
        jumpToBottomBackground.isHidden = true
        jumpToBottomBackground.update(cornerRadius: 21, tintAlpha: 0.22, borderAlpha: 0.24)
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
