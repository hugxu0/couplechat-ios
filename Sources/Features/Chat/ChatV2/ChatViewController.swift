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
    var pendingMedia: [ChatPendingMedia] = []
    var photoPickerPurpose: PhotoPickerPurpose = .messageMedia

    let composer = ChatComposerView()

    private var theme: ThemeManager
    private var onMediaTap: (String) -> Void
    private var collectionView: UICollectionView!
    private let refreshControl = UIRefreshControl()
    private let bottomStack = UIStackView()
    private let panelContainer = UIView()
    private let jumpToBottomBackground = ChatGlassView(style: .systemThinMaterial, cornerRadius: 21)
    private let jumpToBottomButton = UIButton(type: .system)
    private let bottomRefreshIndicator = UIActivityIndicatorView(style: .medium)
    private var stickerPanel: ChatStickerPanelView?
    private var isHistoryRefreshing = false
    private var isNewerRefreshing = false

    private var composerHeightConstraint: NSLayoutConstraint!
    private var panelHeightConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var keyboardOverlap: CGFloat = 0
    private var currentListBottomInset: CGFloat = 0
    private var topOverlayInset: CGFloat = 96
    private var composerUsesLightContent = false

    private var cancellables: Set<AnyCancellable> = []
    private var timelineItems: [ChatTimelineItem] = []
    private var messagesById: [String: ChatMessage] = [:]
    private var layoutHeightCache: [ChatMessageLayout: CGFloat] = [:]
    private var lastMeasuredWidth: CGFloat = 0
    private var highlightedMessageId: String?
    private var pendingTopAnchor: (itemId: String, offset: CGFloat)?
    private var didInitialScroll = false
    private var initialPositioningScheduled = false
    private var inputState: ChatInputState = .idle
    private var browsingHistoricalWindow = false
    var stickToLatestAfterNextReload = false
    private var activeJumpID: UUID?

    private var voicePlayer: AVPlayer?
    private var voicePlaybackEndObserver: NSObjectProtocol?
    private var voicePlaybackTimeObserver: Any?
    private var playingVoiceMessageID: String?
    private var playingVoiceProgress: CGFloat = 0

    private var replyTarget: ChatMessage?

    var isRecording = false
    var recordingCancelled = false
    var recordingElapsed: TimeInterval = 0
    var recordingTimer: Timer?
    var audioRecorder: AVAudioRecorder?
    var recordingURL: URL?
    var recordingStartDate: Date?

    init(
        channel: ChatChannel,
        store: ChatStore,
        theme: ThemeManager,
        composerUsesLightContent: Bool,
        onMediaTap: @escaping (String) -> Void
    ) {
        self.channel = channel
        self.store = store
        self.theme = theme
        self.composerUsesLightContent = composerUsesLightContent
        self.onMediaTap = onMediaTap
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        voicePlayer?.pause()
        if let observer = voicePlaybackEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = voicePlaybackTimeObserver {
            voicePlayer?.removeTimeObserver(observer)
        }
    }

    func updateEnvironment(
        store: ChatStore,
        theme: ThemeManager,
        topOverlayInset: CGFloat,
        composerUsesLightContent: Bool,
        onMediaTap: @escaping (String) -> Void
    ) {
        let storeChanged = self.store !== store
        self.store = store
        self.theme = theme
        self.composerUsesLightContent = composerUsesLightContent
        self.onMediaTap = onMediaTap
        composer.applyTheme(theme, usesLightContent: composerUsesLightContent)
        applyAccentColor()
        setTopOverlayInset(topOverlayInset)
        if storeChanged {
            bindStore()
            layoutHeightCache.removeAll()
            reloadTimeline(animated: false)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        buildCollectionView()
        buildBottomDock()
        configureKeyboardObservers()
        bindStore()
        composer.delegate = self
        composer.applyTheme(theme, usesLightContent: composerUsesLightContent)
        applyAccentColor()
        installStickerPanel()
        store.ensureLocalMessages(channel)
        store.markRead(channel)
        reloadTimeline(animated: false)
    }

    func setTopOverlayInset(_ inset: CGFloat) {
        let clamped = max(72, ceil(inset))
        guard abs(topOverlayInset - clamped) > 0.5 else { return }
        topOverlayInset = clamped
        applyInputLayout(duration: 0, curve: .curveEaseOut)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyInputLayout(duration: 0, curve: .curveEaseOut)
        scheduleInitialTimelinePositioning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = floor(collectionView.bounds.width)
        if width > 0, abs(width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = width
            layoutHeightCache.removeAll()
            collectionView.collectionViewLayout.invalidateLayout()
        }
        scheduleInitialTimelinePositioning()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        // 消息气泡使用已解析的静态前景/背景色；系统外观改变时必须重新配置单元，
        // 避免保留浅色背景却让动态 .label 变成白字。
        composer.applyTheme(theme, usesLightContent: composerUsesLightContent)
        layoutHeightCache.removeAll()
        collectionView.collectionViewLayout.invalidateLayout()
        UIView.performWithoutAnimation {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
        }
        applyInputLayout(duration: 0, curve: .curveEaseOut)
    }

    func performJump(_ command: ChatV2JumpCommand) {
        guard activeJumpID != command.id else { return }
        activeJumpID = command.id
        switch command.action {
        case .message(let message):
            store.ensureMessageLoaded(message, channel: channel)
            completeJump(to: message)
        case .date(let date):
            Task { @MainActor [weak self] in
                guard let self,
                      let target = await self.store.ensureDateLoaded(date, channel: self.channel) else { return }
                self.completeJump(to: target)
            }
        }
    }

    private func completeJump(to target: ChatMessage) {
        browsingHistoricalWindow = true
        reloadTimeline(animated: false)
        view.layoutIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.scrollToMessage(id: target.id, highlighted: true)
        }
    }

    private func buildCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.estimatedItemSize = .zero

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ChatTimeCell.self, forCellWithReuseIdentifier: ChatTimeCell.reuseId)
        collectionView.register(ChatSystemCell.self, forCellWithReuseIdentifier: ChatSystemCell.reuseId)
        collectionView.register(ChatNativeMessageCell.self, forCellWithReuseIdentifier: ChatNativeMessageCell.reuseId)
        refreshControl.tintColor = .white
        refreshControl.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        refreshControl.addTarget(self, action: #selector(handleHistoryRefresh), for: .valueChanged)
        collectionView.refreshControl = refreshControl
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCollectionTap(_:)))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
    }

    private func buildBottomDock() {
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
            self.composerHeightConstraint.constant = height
            self.applyInputLayout(duration: 0.18, curve: .curveEaseOut, forceBottom: self.composer.textView.isFirstResponder)
        }

        panelHeightConstraint = panelContainer.heightAnchor.constraint(equalToConstant: 0)
        panelHeightConstraint.isActive = true
        // 系统原生键盘布局锚点，避免手动转换 SwiftUI/窗口坐标造成输入栏悬空。
        bottomConstraint = bottomStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint
        ])
    }

    private func buildJumpToBottomButton() {
        jumpToBottomBackground.translatesAutoresizingMaskIntoConstraints = false
        jumpToBottomBackground.alpha = 0
        jumpToBottomBackground.isHidden = true
        jumpToBottomBackground.update(cornerRadius: 21, tintAlpha: 0.22, borderAlpha: 0.24)
        view.addSubview(jumpToBottomBackground)
        bottomRefreshIndicator.translatesAutoresizingMaskIntoConstraints = false
        bottomRefreshIndicator.hidesWhenStopped = true
        bottomRefreshIndicator.color = theme.accent.uiColor
        view.addSubview(bottomRefreshIndicator)

        jumpToBottomButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        jumpToBottomButton.backgroundColor = .clear
        jumpToBottomButton.translatesAutoresizingMaskIntoConstraints = false
        jumpToBottomButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.browsingHistoricalWindow = false
            self.store.ensureLocalMessages(self.channel)
            self.reloadTimeline(animated: false)
            self.scrollToBottom(animated: true)
            self.updateJumpToBottomVisibility(animated: true)
        }, for: .touchUpInside)
        jumpToBottomBackground.addSubview(jumpToBottomButton)

        NSLayoutConstraint.activate([
            jumpToBottomBackground.widthAnchor.constraint(equalToConstant: 42),
            jumpToBottomBackground.heightAnchor.constraint(equalToConstant: 42),
            jumpToBottomBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            jumpToBottomBackground.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -12),
            bottomRefreshIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomRefreshIndicator.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -14),

            jumpToBottomButton.leadingAnchor.constraint(equalTo: jumpToBottomBackground.leadingAnchor),
            jumpToBottomButton.trailingAnchor.constraint(equalTo: jumpToBottomBackground.trailingAnchor),
            jumpToBottomButton.topAnchor.constraint(equalTo: jumpToBottomBackground.topAnchor),
            jumpToBottomButton.bottomAnchor.constraint(equalTo: jumpToBottomBackground.bottomAnchor)
        ])
    }

    private func applyAccentColor() {
        jumpToBottomButton.tintColor = theme.accent.uiColor
        bottomRefreshIndicator.color = theme.accent.uiColor
    }

    private func installStickerPanel() {
        let panel = ChatStickerPanelView(store: StickerStore.shared, accentColor: theme.accent.uiColor)
        panel.delegate = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            panel.topAnchor.constraint(equalTo: panelContainer.topAnchor),
            panel.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor)
        ])
        stickerPanel = panel
    }

    private func configureKeyboardObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboardNotification(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboardNotification(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func handleKeyboardNotification(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? UIView.AnimationOptions.curveEaseOut.rawValue
        let curve = UIView.AnimationOptions(rawValue: curveRaw << 16)
        let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let frameInView = view.convert(endFrame, from: view.window)
        let overlap = max(0, view.bounds.maxY - frameInView.minY)

        if case .emojiPanel = inputState, overlap > 0 {
            hidePanel(animated: false)
        }
        keyboardOverlap = overlap
        applyInputLayout(duration: duration, curve: curve, forceBottom: true)
    }

    private func bindStore() {
        cancellables.removeAll()
        messageStore.$messagesByChannel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleStoreChange()
            }
            .store(in: &cancellables)

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.composer.setTypingVisible(self.channel == .ai && self.store.aiTyping)
            }
            .store(in: &cancellables)
    }

    private func handleStoreChange() {
        composer.setTypingVisible(channel == .ai && store.aiTyping)
        reloadTimeline(animated: true)
        store.markRead(channel)
    }

    private func reloadTimeline(animated: Bool) {
        guard collectionView != nil else { return }
        let wasNearLatestBottom = isNearBottom() && isNearLatestWindow()
        let oldAnchor = visibleTimelineAnchor()
        let oldLastMessageId = lastMessageId(in: timelineItems)
        let oldMessageCount = messageCount(in: timelineItems)
        timelineItems = makeTimelineItems()
        let newLastMessageId = lastMessageId(in: timelineItems)
        let newMessageCount = messageCount(in: timelineItems)

        let reload = {
            self.collectionView.reloadData()
            self.collectionView.layoutIfNeeded()
        }

        if animated {
            reload()
        } else {
            UIView.performWithoutAnimation(reload)
        }

        if stickToLatestAfterNextReload {
            stickToLatestAfterNextReload = false
            browsingHistoricalWindow = false
            scrollToBottom(animated: animated)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToBottom(animated: false)
            }
        } else if let anchor = pendingTopAnchor ?? (!wasNearLatestBottom ? oldAnchor : nil),
           indexPath(forItemId: anchor.itemId) != nil {
            restoreTimelineAnchor(anchor)
            pendingTopAnchor = nil
        } else if wasNearLatestBottom && oldLastMessageId != newLastMessageId && newMessageCount > oldMessageCount {
            scrollToBottom(animated: animated)
        }
        scheduleInitialTimelinePositioning()
        updateJumpToBottomVisibility(animated: animated)
    }

    private func makeTimelineItems() -> [ChatTimelineItem] {
        let messages = store.messages(for: channel)
        messagesById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        var items: [ChatTimelineItem] = []
        for (index, message) in messages.enumerated() {
            if showTimeSeparator(index, messages: messages) {
                items.append(.time(id: "time-\(message.id)", text: Self.timeLabel(for: message.date)))
            }
            if message.kind == "system" {
                items.append(.system(id: "system-\(message.id)", text: message.text))
            } else {
                items.append(.message(id: message.id))
            }
        }
        return items
    }

    private func showTimeSeparator(_ index: Int, messages: [ChatMessage]) -> Bool {
        guard index > 0 else { return true }
        return messages[index].ts - messages[index - 1].ts > 8 * 60 * 1000
    }

    private func groupedWithPrevious(_ message: ChatMessage) -> Bool {
        let messages = store.messages(for: channel)
        guard let index = messages.firstIndex(where: { $0.id == message.id }),
              index > 0,
              !showTimeSeparator(index, messages: messages) else { return false }
        let previous = messages[index - 1]
        return previous.sender == message.sender && previous.kind != "system"
    }

    private func visibleTimelineAnchor() -> (itemId: String, offset: CGFloat)? {
        let visible = collectionView.indexPathsForVisibleItems.sorted {
            let lhsFrame = collectionView.layoutAttributesForItem(at: $0)?.frame ?? .zero
            let rhsFrame = collectionView.layoutAttributesForItem(at: $1)?.frame ?? .zero
            return lhsFrame.minY < rhsFrame.minY
        }
        for indexPath in visible {
            guard indexPath.item < timelineItems.count,
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { continue }
            return (timelineItems[indexPath.item].id, frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func restoreTimelineAnchor(_ anchor: (itemId: String, offset: CGFloat)) {
        guard let indexPath = indexPath(forItemId: anchor.itemId),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        setClampedContentOffsetY(frame.minY - anchor.offset)
    }

    private func indexPath(forItemId id: String) -> IndexPath? {
        guard let index = timelineItems.firstIndex(where: { $0.id == id }) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    private func setClampedContentOffsetY(_ targetY: CGFloat) {
        let minY = -collectionView.contentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.contentInset.bottom)
        collectionView.contentOffset.y = min(max(targetY, minY), maxY)
    }

    private func indexPath(forMessageId id: String) -> IndexPath? {
        guard let index = timelineItems.firstIndex(where: {
            if case .message(let messageId) = $0 { return messageId == id }
            return false
        }) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    private func lastMessageId(in items: [ChatTimelineItem]) -> String? {
        for item in items.reversed() {
            if case .message(let id) = item {
                return id
            }
        }
        return nil
    }

    private func messageCount(in items: [ChatTimelineItem]) -> Int {
        items.reduce(0) { count, item in
            if case .message = item { return count + 1 }
            return count
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard collectionView != nil else { return }
        collectionView.layoutIfNeeded()
        let y = collectionView.contentSize.height - collectionView.bounds.height + collectionView.contentInset.bottom
        let minY = -collectionView.contentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: max(minY, y)), animated: animated)
        updateJumpToBottomVisibility(animated: animated)
    }

    /// 只在「首批消息 + collection 尺寸 + 输入栏 inset」都稳定后贴底一次。
    /// 这样不会先按旧 contentSize 显示，再随异步数据库结果或布局失效向上弹。
    private func scheduleInitialTimelinePositioning() {
        guard !didInitialScroll,
              !initialPositioningScheduled,
              !timelineItems.isEmpty,
              viewIfLoaded?.window != nil else { return }
        initialPositioningScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.initialPositioningScheduled = false
            guard !self.didInitialScroll,
                  !self.timelineItems.isEmpty,
                  self.collectionView.bounds.height > 0 else { return }
            self.applyInputLayout(duration: 0, curve: .curveEaseOut, forceBottom: true)
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
            self.scrollToBottom(animated: false)
            self.didInitialScroll = true
            self.updateJumpToBottomVisibility(animated: false)
        }
    }

    private func updateJumpToBottomVisibility(animated: Bool) {
        guard jumpToBottomBackground.superview != nil else { return }
        let visible = didInitialScroll && !isNearBottom()
        let changes = {
            self.jumpToBottomBackground.alpha = visible ? 1 : 0
        }
        if visible {
            jumpToBottomBackground.isHidden = false
        }
        let completion: (Bool) -> Void = { _ in
            if !visible {
                self.jumpToBottomBackground.isHidden = true
            }
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    private func scrollToMessage(id: String, highlighted: Bool, position: UICollectionView.ScrollPosition = .centeredVertically) {
        guard let indexPath = indexPath(forMessageId: id) else { return }
        collectionView.scrollToItem(at: indexPath, at: position, animated: false)
        guard highlighted else { return }
        highlightedMessageId = id
        layoutHeightCache.removeAll()
        reloadTimeline(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.highlightedMessageId == id else { return }
            self.highlightedMessageId = nil
            self.layoutHeightCache.removeAll()
            self.reloadTimeline(animated: true)
        }
    }

    private func isNearBottom() -> Bool {
        guard collectionView != nil else { return true }
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        return collectionView.contentOffset.y >= maxOffset - 44
    }

    private func isNearLatestWindow() -> Bool {
        guard let currentLast = store.messages(for: channel).last else { return true }
        let localLatest = ChatLocalDatabase.shared.fetchLatestMessages(channel: channel.rawValue, limit: 1).last
        return localLatest?.id == currentLast.id
    }

    private func setReplyTarget(_ message: ChatMessage) {
        replyTarget = message
        composer.setReplyPreview(replyPreview(for: message))
        composer.focusTextInput()
    }

    private func clearReplyTarget() {
        replyTarget = nil
        composer.setReplyPreview(nil)
    }

    private func replyPreview(for message: ChatMessage) -> String {
        let body: String
        switch message.type {
        case "sticker": body = "[表情]"
        case "image": body = "[图片]"
        case "video": body = "[视频]"
        case "voice": body = "[语音]"
        case "file": body = "[文件]"
        default: body = message.displayText
        }
        return "\(message.senderName): \(body)"
    }

    private func sendText(_ text: String) {
        let target = replyTarget
        clearReplyTarget()
        composer.clearText()
        stickToLatestAfterNextReload = true
        store.sendText(
            text,
            channel: channel,
            replyTo: target?.id,
            replyPreview: target.map { replyPreview(for: $0) }
        )
        reloadTimeline(animated: false)
        hidePanel(animated: true)
    }

    private func sendSticker(_ sticker: Sticker) {
        Haptics.light()
        stickToLatestAfterNextReload = true
        store.sendSticker(url: sticker.url, channel: channel)
        reloadTimeline(animated: false)
    }

    private func summonDaju() {
        let textView = composer.textView
        if !(textView.text ?? "").contains("@大橘") {
            textView.text = textView.text.isEmpty ? "@大橘 " : "@大橘 " + textView.text
            composer.textViewDidChange(textView)
        }
        composer.focusTextInput()
    }

    private func toggleStickerPanel() {
        if panelHeightConstraint.constant > 0 {
            hidePanel(animated: true)
            composer.focusTextInput()
        } else {
            showPanel(height: 300)
        }
    }

    private func showPanel(height: CGFloat) {
        inputState = .emojiPanel
        composer.resignTextInput()
        keyboardOverlap = 0
        panelContainer.isHidden = false
        panelHeightConstraint.constant = max(300, height)
        applyInputLayout(duration: 0.24, curve: .curveEaseOut, forceBottom: true)
    }

    private func hidePanel(animated: Bool) {
        guard panelHeightConstraint.constant > 0 else { return }
        panelHeightConstraint.constant = 0
        panelContainer.isHidden = true
        if case .emojiPanel = inputState {
            inputState = .idle
        }
        if animated {
            applyInputLayout(duration: 0.2, curve: .curveEaseOut, forceBottom: true)
        } else {
            applyInputLayout(duration: 0, curve: .curveEaseOut, forceBottom: true)
        }
    }

    private func dismissInput(animated: Bool) {
        composer.resignTextInput()
        hidePanel(animated: animated)
        inputState = .idle
    }

    @objc private func handleCollectionTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
           let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell {
            let localPoint = collectionView.convert(point, to: cell)
            if cell.containsBubble(point: localPoint) {
                return
            }
        }
        dismissInput(animated: true)
    }

    @objc private func handleHistoryRefresh() {
        guard !isHistoryRefreshing else { return }
        isHistoryRefreshing = true
        let boundaryItemId = timelineItems.first(where: {
            if case .message = $0 { return true }
            return false
        })?.id
        if let boundaryItemId {
            let seamOffset = max(topOverlayInset + 18, collectionView.bounds.height - currentListBottomInset - 96)
            pendingTopAnchor = (itemId: boundaryItemId, offset: seamOffset)
        } else {
            pendingTopAnchor = visibleTimelineAnchor()
        }
        Task { [weak self] in
            guard let self else { return }
            await self.store.loadOlderAsync(self.channel)
            await MainActor.run {
                self.reloadTimeline(animated: false)
                self.refreshControl.endRefreshing()
                self.isHistoryRefreshing = false
                self.updateJumpToBottomVisibility(animated: true)
            }
        }
    }

    private func handleNewerRefresh() {
        guard !isNewerRefreshing,
              !store.isLoadingNewer(channel),
              !store.messages(for: channel).isEmpty else { return }
        isNewerRefreshing = true
        pendingTopAnchor = visibleTimelineAnchor()
        bottomRefreshIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            await self.store.loadNewerAsync(self.channel)
            await MainActor.run {
                self.reloadTimeline(animated: false)
                if self.isNearLatestWindow() {
                    self.browsingHistoricalWindow = false
                }
                self.isNewerRefreshing = false
                self.bottomRefreshIndicator.stopAnimating()
                self.updateJumpToBottomVisibility(animated: true)
            }
        }
    }

    private func applyInputLayout(duration: TimeInterval, curve: UIView.AnimationOptions, forceBottom: Bool = false) {
        guard collectionView != nil else { return }
        let isUserScrolling = collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        let wasNearBottom = isNearBottom()
        let anchor = wasNearBottom ? nil : visibleTimelineAnchor()
        let panelHeight = panelContainer.isHidden ? 0 : panelHeightConstraint.constant
        let dockHeight = composerHeightConstraint.constant + panelHeight
        let coveredBottom = max(keyboardOverlap, view.safeAreaInsets.bottom)
        let bottomInset = dockHeight + coveredBottom + 8
        let bottomInsetDelta = bottomInset - currentListBottomInset
        currentListBottomInset = bottomInset

        let updates = {
            self.collectionView.contentInset.top = self.topOverlayInset
            self.collectionView.verticalScrollIndicatorInsets.top = self.topOverlayInset
            self.collectionView.contentInset.bottom = bottomInset
            self.collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
            self.view.layoutIfNeeded()
            if forceBottom {
                self.scrollToBottom(animated: false)
            } else if wasNearBottom && !isUserScrolling {
                self.setClampedContentOffsetY(self.collectionView.contentOffset.y + bottomInsetDelta)
            } else if let anchor, !isUserScrolling {
                self.restoreTimelineAnchor(anchor)
            }
            self.updateJumpToBottomVisibility(animated: duration > 0)
        }
        guard duration > 0 else {
            UIView.performWithoutAnimation(updates)
            return
        }
        UIView.animate(withDuration: duration, delay: 0, options: [curve, .beginFromCurrentState, .allowUserInteraction], animations: updates)
    }

    private func showAttachmentMenu() {
        inputState = .attachmentPicking
        hidePanel(animated: true)
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "照片或视频", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "文件", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.inputState = .idle
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = composer
            popover.sourceRect = composer.bounds
        }
        present(sheet, animated: true)
    }

    private func presentPhotoPicker() {
        photoPickerPurpose = .messageMedia
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 9
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentStickerPicker(groupId: String) {
        photoPickerPurpose = .sticker(groupId: groupId)
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func sendPendingMedia() {
        let items = pendingMedia
        guard !items.isEmpty else { return }
        let caption = composer.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingMedia = []
        composer.setMediaPreviews([])
        composer.clearText()
        stickToLatestAfterNextReload = true
        for (index, item) in items.enumerated() {
            store.sendMedia(
                data: item.data,
                mimeType: item.mimeType,
                preferredType: item.messageType,
                localPreviewURL: item.localPreviewURL,
                channel: channel,
                displayText: index == 0 && !caption.isEmpty ? caption : nil
            )
        }
        reloadTimeline(animated: false)
    }

    func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        stickToLatestAfterNextReload = true
        store.sendMedia(
            data: data,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            preferredType: "file",
            localPreviewURL: nil,
            channel: channel,
            displayText: url.lastPathComponent
        )
        reloadTimeline(animated: false)
    }

    func addStickerImage(_ image: UIImage, to groupId: String) {
        Task {
            guard let url = await store.uploadSticker(image) else {
                Haptics.medium()
                return
            }
            StickerStore.shared.add(url: url, groupId: groupId)
            Haptics.light()
        }
    }

    private func showStickerManage() {
        let alert = UIAlertController(title: "表情管理", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "新建分组", style: .default) { _ in
            self.showCreateStickerGroup()
        })
        let deletableGroups = StickerStore.shared.sortedGroups.filter { $0.id != StickerStore.defaultGroupId }
        for group in deletableGroups {
            alert.addAction(UIAlertAction(title: "删除分组：\(group.name)", style: .destructive) { _ in
                StickerStore.shared.deleteGroup(group)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = panelContainer
            popover.sourceRect = panelContainer.bounds
        }
        present(alert, animated: true)
    }

    private func showCreateStickerGroup() {
        let alert = UIAlertController(title: "新建分组", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "分组名（最多 8 字）"
        }
        alert.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            let name = alert.textFields?.first?.text ?? ""
            _ = StickerStore.shared.createGroup(name: name)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private var peerAvatar: String {
        if channel == .ai { return "🐱" }
        return store.partner?.avatar ?? AccountPresentation.avatar(for: store.partner?.username ?? "si")
    }

    private var peerAvatarURL: URL? {
        channel == .ai ? nil : store.avatarURL(for: store.partner?.username)
    }

    private var myAvatar: String {
        AccountPresentation.avatar(for: store.session?.username ?? "xu")
    }

    private var myAvatarURL: URL? {
        store.avatarURL(for: store.session?.username)
    }

    private static func timeLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "昨天 HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }
}

extension ChatViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        timelineItems.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = timelineItems[indexPath.item]
        switch item {
        case .time(_, let text):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatTimeCell.reuseId, for: indexPath) as! ChatTimeCell
            cell.configure(text: text)
            return cell
        case .system(_, let text):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatSystemCell.reuseId, for: indexPath) as! ChatSystemCell
            cell.configure(text: text)
            return cell
        case .message(let id):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ChatNativeMessageCell.reuseId, for: indexPath) as! ChatNativeMessageCell
            if let message = messagesById[id] {
                let mine = message.sender == store.session?.username
                cell.delegate = self
                cell.configure(
                    message: message,
                    mine: mine,
                    groupedWithPrevious: groupedWithPrevious(message),
                    read: store.partnerHasRead(message),
                    highlighted: highlightedMessageId == message.id,
                    peerAvatar: peerAvatar,
                    myAvatar: myAvatar,
                    peerAvatarURL: peerAvatarURL,
                    myAvatarURL: myAvatarURL,
                    accentColor: theme.accent.uiColor,
                    voicePlaying: playingVoiceMessageID == message.id,
                    voiceProgress: playingVoiceMessageID == message.id ? playingVoiceProgress : 0
                )
            }
            return cell
        }
    }
}

extension ChatViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard indexPath.item < timelineItems.count else { return .zero }
        let width = collectionView.bounds.width
        switch timelineItems[indexPath.item] {
        case .time:
            return CGSize(width: width, height: 40)
        case .system(_, let text):
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width - 48, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.systemFont(ofSize: 12)],
                context: nil
            )
            return CGSize(width: width, height: max(32, ceil(rect.height) + 16))
        case .message(let id):
            guard let message = messagesById[id] else { return CGSize(width: width, height: 1) }
            let mine = message.sender == store.session?.username
            let grouped = groupedWithPrevious(message)
            let key = ChatMessageLayout.key(
                message: message,
                width: width,
                mine: mine,
                groupedWithPrevious: grouped,
                highlighted: highlightedMessageId == message.id
            )
            if let cached = layoutHeightCache[key] {
                return CGSize(width: width, height: cached)
            }
            let height = ChatTimelineMetrics.messageHeight(for: message, containerWidth: width, groupedWithPrevious: grouped)
            layoutHeightCache[key] = height
            return CGSize(width: width, height: height)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        hidePanel(animated: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateJumpToBottomVisibility(animated: false)
        let pullDistance = -(scrollView.contentOffset.y + scrollView.contentInset.top)
        let bottomPullDistance = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentInset.bottom - scrollView.contentSize.height
        if scrollView.isDragging,
           pullDistance > 42,
           !isHistoryRefreshing,
           !store.isLoadingOlder(channel),
           !store.messages(for: channel).isEmpty {
            refreshControl.beginRefreshing()
            handleHistoryRefresh()
        }
        if scrollView.isDragging,
           bottomPullDistance > 48,
           !isNewerRefreshing,
           !store.isLoadingNewer(channel),
           !isNearLatestWindow() {
            handleNewerRefresh()
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.item < timelineItems.count,
              case .message(let id) = timelineItems[indexPath.item],
              let message = messagesById[id],
              let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell else { return nil }

        let convertedPoint = collectionView.convert(point, to: cell)
        guard cell.containsBubble(point: point) || cell.containsBubble(point: convertedPoint) else { return nil }

        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIAction] = []
            if message.type == "text" {
                actions.append(UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = message.displayText
                })
            }
            actions.append(UIAction(title: "引用", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                self.setReplyTarget(message)
            })
            let withinTwoMin = message.sender == self.store.session?.username &&
                (Date().timeIntervalSince1970 * 1000 - message.ts) < 120_000
            if withinTwoMin && !message.pending && !message.failed {
                actions.append(UIAction(title: "撤回", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.store.recallMessage(message, channel: self.channel)
                })
            }
            return UIMenu(children: actions)
        }
    }

    func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? String,
              let indexPath = indexPath(forMessageId: id),
              let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell else { return nil }
        return cell.bubbleTargetedPreview()
    }

    func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? String,
              let indexPath = indexPath(forMessageId: id),
              let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell else { return nil }
        return cell.bubbleTargetedPreview()
    }
}

extension ChatViewController: ChatTimelineCellDelegate {
    func chatCellDidTapMedia(_ cell: ChatNativeMessageCell) {
        guard let indexPath = collectionView.indexPath(for: cell),
              case .message(let id) = timelineItems[indexPath.item],
              let message = messagesById[id] else { return }
        if message.type == "voice" {
            toggleVoicePlayback(message)
        } else if message.type == "file", let url = message.mediaURL {
            UIApplication.shared.open(url)
        } else {
            onMediaTap(id)
        }
    }

    func chatCellDidTapRetry(_ cell: ChatNativeMessageCell) {
        guard let indexPath = collectionView.indexPath(for: cell),
              case .message(let id) = timelineItems[indexPath.item],
              let message = messagesById[id] else { return }
        store.resend(message)
    }
}

private extension ChatViewController {
    func toggleVoicePlayback(_ message: ChatMessage) {
        guard let url = message.mediaURL else { return }
        if playingVoiceMessageID == message.id {
            stopVoicePlayback()
            return
        }

        stopVoicePlayback(deactivateSession: false)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            return
        }

        let player = AVPlayer(url: url)
        voicePlayer = player
        playingVoiceMessageID = message.id
        playingVoiceProgress = 0
        voicePlaybackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopVoicePlayback()
            }
        }
        voicePlaybackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playingVoiceMessageID == message.id,
                      let duration = self.voicePlayer?.currentItem?.duration.seconds,
                      duration.isFinite,
                      duration > 0 else { return }
                self.playingVoiceProgress = min(1, max(0, CGFloat(time.seconds / duration)))
                self.updateVoiceMessageCell(message.id, isPlaying: true)
            }
        }
        player.play()
        updateVoiceMessageCell(message.id, isPlaying: true)
    }

    func stopVoicePlayback(deactivateSession: Bool = true) {
        let previousID = playingVoiceMessageID
        voicePlayer?.pause()
        if let observer = voicePlaybackTimeObserver {
            voicePlayer?.removeTimeObserver(observer)
            voicePlaybackTimeObserver = nil
        }
        voicePlayer = nil
        playingVoiceMessageID = nil
        playingVoiceProgress = 0
        if let observer = voicePlaybackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            voicePlaybackEndObserver = nil
        }
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let previousID { updateVoiceMessageCell(previousID, isPlaying: false) }
    }

    func updateVoiceMessageCell(_ id: String, isPlaying: Bool) {
        guard let indexPath = indexPath(forMessageId: id),
              collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        (collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell)?
            .setVoicePlayback(progress: playingVoiceProgress, isPlaying: isPlaying)
    }
}

extension ChatViewController: ChatStickerPanelViewDelegate {
    func stickerPanel(_ panel: ChatStickerPanelView, didSelectEmoji emoji: String) {
        composer.textView.insertText(emoji)
        composer.textViewDidChange(composer.textView)
    }

    func stickerPanel(_ panel: ChatStickerPanelView, didSelectSticker sticker: Sticker) {
        sendSticker(sticker)
    }

    func stickerPanel(_ panel: ChatStickerPanelView, didRequestAddStickerTo groupId: String) {
        presentStickerPicker(groupId: groupId)
    }

    func stickerPanelDidRequestManage(_ panel: ChatStickerPanelView) {
        showStickerManage()
    }
}

extension ChatViewController: ChatComposerViewDelegate {
    func composerDidSendText(_ text: String) {
        sendText(text)
    }

    func composerDidTapCat() {
        summonDaju()
    }

    func composerDidTapEmoji() {
        toggleStickerPanel()
    }

    func composerDidTapAttachment() {
        showAttachmentMenu()
    }

    func composerDidTapSendMedia() {
        sendPendingMedia()
    }

    func composerDidRemoveMedia(id: String) {
        pendingMedia.removeAll { $0.id == id }
        composer.setMediaPreviews(pendingMedia)
    }

    func composerDidCancelReply() {
        clearReplyTarget()
    }

    func composerTextDidBeginEditing() {
        inputState = .editing
        hidePanel(animated: true)
        scrollToBottom(animated: true)
    }

    func composerRecordingBegan() {
        inputState = .recording(cancelled: false)
        beginRecording()
    }

    func composerRecordingMoved(cancelled: Bool) {
        inputState = .recording(cancelled: cancelled)
        recordingCancelled = cancelled
        composer.setRecording(elapsed: recordingElapsed, cancelled: cancelled)
    }

    func composerRecordingEnded(cancelled: Bool) {
        inputState = .idle
        finishRecording(cancelled: cancelled || recordingCancelled)
    }
}
