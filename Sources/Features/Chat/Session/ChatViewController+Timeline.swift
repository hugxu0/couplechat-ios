import AVFoundation
import Combine
import SafariServices
import UIKit

extension ChatViewController {
    func bindStore() {
        cancellables.removeAll()
        messageStore.timelineStore.$messagesByChannel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleStoreChange() }
            .store(in: &cancellables)

        // 已读状态与消息数组是两条独立的发布链。过去这里只监听消息，导致
        // read:update 已经到达内存后，屏幕上的“未读”仍要等下一条消息才刷新。
        messageStore.timelineStore.$readStates
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.timelineController != nil else { return }
                self.timelineController.updatePresentation(self.makeTimelinePresentation())
                self.timelineController.invalidateReadReceiptAppearance()
            }
            .store(in: &cancellables)

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.composer.setTypingVisible(false)
                    self.composer.setCatThinking(self.store.isAIComposing(in: self.channel))
                    let preservingPaginationWindow = self.isNewerRefreshing
                        || self.suppressesNextPaginationStoreChange
                        || self.store.isLoadingNewer(self.channel)
                    self.reloadTimeline(
                        animated: true,
                        preservingWindowState: preservingPaginationWindow)
                }
            }
            .store(in: &cancellables)
    }

    func handleStoreChange() {
        composer.setTypingVisible(false)
        composer.setCatThinking(store.isAIComposing(in: channel))
        let messages = store.messages(for: channel)
        // 向下翻页本身会把一批更晚的历史消息追加到尾部；这不是实时收消息，
        // 不能因此把阅读位置标记成“下方有新消息”。翻页期间保留当前窗口状态，
        // 等 handleNewerRefresh 根据是否已到最新窗口统一处理。
        let isAppendingNewerHistory = suppressesNextPaginationStoreChange
            || isNewerRefreshing
            || store.isLoadingNewer(channel)
        if suppressesNextPaginationStoreChange {
            suppressesNextPaginationStoreChange = false
        }
        if !isAppendingNewerHistory,
           let previousLastID = lastRenderedMessageID,
           let previousLastIndex = messages.firstIndex(where: { $0.id == previousLastID }),
           previousLastIndex < messages.index(before: messages.endIndex) {
            let appendedMessages = messages[messages.index(after: previousLastIndex)...]
            let currentUsername = store.session?.username
            let containsIncoming = appendedMessages.contains { $0.sender != currentUsername }
            timelineController.registerReceivedMessage(isMine: !containsIncoming)
        }
        reloadTimeline(
            animated: true,
            preservingWindowState: isAppendingNewerHistory)
    }

    func reloadTimeline(animated: Bool, preservingWindowState: Bool = false) {
        guard timelineController != nil else { return }
        timelineController.updatePresentation(makeTimelinePresentation())
        // 已经通过搜索进入历史窗口后，后续刷新不能仅因为内存列表里
        // 拼进了最新消息，就把“浏览历史”状态改成贴底状态。否则
        // ChatTimelineController 会在本次 reload 中执行 followLatest。
        if !preservingWindowState,
           !timelineController.browsingHistoricalWindow {
            timelineController.browsingHistoricalWindow = !isNearLatestWindow()
        }
        let messages = store.messages(for: channel)
        timelineController.reload(messages: messages, activity: nil, animated: animated)
        if !hasCompletedEntryBootstrap { collectionView.alpha = 0 }
        lastRenderedMessageID = messages.last?.id
        updateJumpToBottomVisibility(animated: animated)
        // diff/reload 时 UIKit 不保证仍在屏幕内的 cell 再次触发 willDisplay。
        // 下一轮布局完成后按真实可见区域补报，避免聊天页已展示消息却漏发回执。
        DispatchQueue.main.async { [weak self] in
            self?.reportDisplayedMessagesAsRead()
        }
    }

    func isNearLatestWindow() -> Bool {
        store.isShowingLatestWindow(channel)
    }

    func handleHistoryRefresh() {
        guard !isHistoryRefreshing,
              !store.isLoadingOlder(channel),
              !store.messages(for: channel).isEmpty else {
            timelineController.refreshControl.endRefreshing()
            return
        }
        isHistoryRefreshing = true
        timelineController.captureBoundaryAnchor()
        Task { [weak self] in
            guard let self else { return }
            defer {
                // UIRefreshControl 的结束状态不能依赖下一轮 @Published reload：
                // 没有更多历史、只命中本地缓存或 reload 被合并时，pendingTopAnchor
                // 可能为空，导致控件一直停在半圈的中间状态。
                UIView.performWithoutAnimation {
                    self.timelineController.refreshControl.endRefreshing()
                }
                self.isHistoryRefreshing = false
                self.updateJumpToBottomVisibility(animated: true)
            }
            await store.loadOlderAsync(channel)
        }
    }

    func handleNewerRefresh() {
        guard !isNewerRefreshing,
              !store.isLoadingNewer(channel),
              !store.messages(for: channel).isEmpty else { return }
        isNewerRefreshing = true
        // 用户正在主动向下翻阅历史；本次分页不能消费之前遗留的贴底意图。
        timelineController.stickToLatestAfterNextReload = false
        suppressesNextPaginationStoreChange = true
        timelineController.captureVisibleAnchor()
        bottomRefreshIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            await store.loadNewerAsync(channel)
            // @Published + receive(on: RunLoop.main) 的回调可能晚于本 Task 返回。
            // 保留分页事务到下一轮投递完成，避免追加页被误判成实时消息。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.suppressesNextPaginationStoreChange = false
                self.isNewerRefreshing = false
                self.bottomRefreshIndicator.stopAnimating()
                // “数据窗口已含最新”不等于“用户已在最新底部”。只有真实 offset
                // 已自然到达底部时才切换状态，绝不在加载完成时主动贴底。
                if self.isNearLatestWindow(), self.timelineController.isNearBottom() {
                    self.timelineController.browsingHistoricalWindow = false
                }
                self.updateJumpToBottomVisibility(animated: true)
            }
        }
    }

    func updateJumpToBottomVisibility(animated: Bool) {
        guard jumpToBottomBackground.superview != nil else { return }
        let visible = timelineController.hasInitialPosition && timelineController.shouldShowJumpToLatest
        let showsNewMessageStatus = timelineController.hasNewMessagesBelow
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = showsNewMessageStatus ? 6 : 0
        configuration.titleLineBreakMode = .byClipping
        configuration.baseForegroundColor = theme.accent.uiColor
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: showsNewMessageStatus ? 13 : 0,
            bottom: 0,
            trailing: showsNewMessageStatus ? 12 : 0)
        var targetWidth: CGFloat = 42
        if showsNewMessageStatus {
            let titleFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(ofSize: 14, weight: .semibold),
                maximumPointSize: 16)
            var title = AttributedString("有新消息")
            title.font = titleFont
            configuration.attributedTitle = title
            targetWidth = 112
        }
        jumpToBottomButton.configuration = configuration
        jumpToBottomButton.accessibilityLabel = showsNewMessageStatus ? "有新消息" : "回到最新消息"
        jumpToBottomButton.accessibilityHint = showsNewMessageStatus ? "轻点查看最新消息" : nil
        jumpToBottomWidthConstraint.constant = targetWidth
        let changes = {
            self.jumpToBottomBackground.alpha = visible ? 1 : 0
            self.view.layoutIfNeeded()
        }
        if visible { jumpToBottomBackground.isHidden = false }
        let completion: (Bool) -> Void = { _ in
            if !visible { self.jumpToBottomBackground.isHidden = true }
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changes,
                completion: completion)
        } else {
            changes()
            completion(true)
        }
    }

    func retry(_ message: ChatMessage) {
        Task { @MainActor in
            let result = await store.retryFailedMessage(message)
            guard result == .missingLocalFile else { return }
            let alert = UIAlertController(
                title: "无法重新发送",
                message: "原文件已不存在，可删除后重新选择。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
        }
    }

    func confirmDiscard(_ message: ChatMessage) {
        let alert = UIAlertController(
            title: "删除失败消息？",
            message: "这只会删除本机尚未发送的消息。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { await self.store.discardFailedMessage(message) }
        })
        present(alert, animated: true)
    }

    func presentMedia(message: ChatMessage, selectedId: String) {
        if message.type == "voice" {
            toggleVoicePlayback(message)
        } else if message.type == "file", let url = message.mediaURL {
            UIApplication.shared.open(url)
        } else {
            Task { [weak self] in
                guard let self else { return }
                let messages = await store.mediaMessages(for: channel, includeFiles: false)
                let items = Array(messages.reversed()).flatMap(MediaBrowserItem.items(for:))
                mediaViewerCoordinator.present(
                    from: self,
                    items: items,
                    selectedId: selectedId,
                    sourceProvider: { [weak self] identifier in
                        self?.timelineController.sourceView(for: identifier)
                    })
            }
        }
    }
}

extension ChatViewController: ChatTimelineControllerDelegate {
    func timelineDidRequestReedit(recalledMessageId: String) {
        guard let draft = store.messageStore.takeRecallDraft(messageId: recalledMessageId) else { return }
        composer.setText(draft.text)
        composer.focusTextInput()
        reloadTimeline(animated: false)
    }

    func timelineDidDecideConfirm(message: ChatMessage, decision: String) {
        guard message.meta?.confirm?.status == "pending" else { return }
        store.confirmAction(messageId: message.id, decision: decision)
    }

    func timelineDidBeginDragging() {
        hidePanel(animated: true)
    }

    func timelineDidScroll() {
        if timelineController.browsingHistoricalWindow,
           !isNewerRefreshing,
           isNearLatestWindow(),
           timelineController.isNearBottom() {
            timelineController.browsingHistoricalWindow = false
            timelineController.clearNewMessagesBelow()
        }
        updateJumpToBottomVisibility(animated: false)
    }

    func timelineDidRequestOlder() {
        handleHistoryRefresh()
    }

    func timelineDidRequestNewer() {
        handleNewerRefresh()
    }

    func timelineDidDisplay(_ message: ChatMessage) {
        guard isChatVisible,
              isForegroundWindowActive else { return }
        store.markRead(channel, through: message.ts)
    }

    func timelineDidSelect(_ action: ChatMessageAction, message: ChatMessage) {
        switch action {
        case .copy:
            UIPasteboard.general.string = message.displayText
        case .reply:
            setReplyTarget(message)
        case .addToStickers:
            guard let url = message.url, !url.isEmpty else { return }
            StickerStore.shared.add(url: url)
            Haptics.light()
        case .addToAlbum:
            presentAlbumPicker(for: message)
        case .recall:
            store.recallMessage(message, channel: channel)
        case .retry:
            retry(message)
        case .discard:
            confirmDiscard(message)
        }
    }

    func timelineDidTapMedia(
        cell: ChatNativeMessageCell,
        message: ChatMessage,
        selectedId: String
    ) {
        presentMedia(message: message, selectedId: selectedId)
    }

    func timelineDidTapLink(_ url: URL) {
        guard presentedViewController == nil else { return }
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .close
        browser.preferredControlTintColor = theme.accent.uiColor
        present(browser, animated: true)
    }

    func timelineDidTapRetry(cell: ChatNativeMessageCell, message: ChatMessage) {
        retry(message)
    }

    func timelineDidTapTranscript(message: ChatMessage) {
        handleTranscriptTap(message)
    }

}

extension ChatViewController {
    func toggleVoicePlayback(_ message: ChatMessage) {
        guard let url = message.mediaURL else { return }
        if playingVoiceMessageID == message.id || loadingVoiceMessageID == message.id {
            stopVoicePlayback()
            return
        }
        stopVoicePlayback(deactivateSession: false)
        loadingVoiceMessageID = message.id
        voicePlaybackLoadTask = Task { [weak self] in
            guard let self else { return }
            guard let localURL = try? await VoiceMediaCache.shared.localURL(for: url),
                  !Task.isCancelled,
                  loadingVoiceMessageID == message.id else {
                if loadingVoiceMessageID == message.id { loadingVoiceMessageID = nil }
                return
            }
            loadingVoiceMessageID = nil
            startVoicePlayback(message, localURL: localURL)
        }
    }

    private func startVoicePlayback(_ message: ChatMessage, localURL: URL) {
        let session = AVAudioSession.sharedInstance()
        do {
            // Chat voice messages must follow both high-quality A2DP headphones and
            // hands-free Bluetooth devices. The speaker remains the fallback route.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true)
        } catch {
            return
        }

        guard let player = try? AVAudioPlayer(contentsOf: localURL) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        player.volume = 1
        guard player.prepareToPlay(), player.play() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        voicePlayer = player
        playingVoiceMessageID = message.id
        playingVoiceProgress = 0
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(voicePlaybackTimerDidFire(_:)),
            userInfo: nil,
            repeats: true)
        voicePlaybackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateVoiceMessageCell(message.id, isPlaying: true)
    }

    @objc private func voicePlaybackTimerDidFire(_ timer: Timer) {
        guard timer === voicePlaybackTimer,
              let player = voicePlayer,
              let messageID = playingVoiceMessageID else { return }
        if player.duration > 0 {
            playingVoiceProgress = min(1, max(0, CGFloat(player.currentTime / player.duration)))
        }
        guard player.isPlaying else {
            stopVoicePlayback()
            return
        }
        updateVoiceMessageCell(messageID, isPlaying: true)
    }

    func stopVoicePlayback(deactivateSession: Bool = true) {
        let previousID = playingVoiceMessageID
        voicePlaybackLoadTask?.cancel()
        voicePlaybackLoadTask = nil
        loadingVoiceMessageID = nil
        voicePlayer?.pause()
        voicePlaybackTimer?.invalidate()
        voicePlaybackTimer = nil
        voicePlayer = nil
        playingVoiceMessageID = nil
        playingVoiceProgress = 0
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let previousID { updateVoiceMessageCell(previousID, isPlaying: false) }
    }

    func updateVoiceMessageCell(_ id: String, isPlaying: Bool) {
        guard let indexPath = timelineController.indexPath(forMessageId: id),
              collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        (collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell)?
            .setVoicePlayback(progress: playingVoiceProgress, isPlaying: isPlaying)
    }
}
