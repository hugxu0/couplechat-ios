import AVFoundation
import Combine
import UIKit

extension ChatViewController {
    func bindStore() {
        cancellables.removeAll()
        messageStore.timelineStore.$messagesByChannel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleStoreChange() }
            .store(in: &cancellables)

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.composer.setTypingVisible(false)
                    self.composer.setCatThinking(self.store.isAIComposing(in: self.channel))
                    self.reloadTimeline(animated: true)
                }
            }
            .store(in: &cancellables)
    }

    func handleStoreChange() {
        composer.setTypingVisible(false)
        composer.setCatThinking(store.isAIComposing(in: channel))
        let newestMessageID = store.messages(for: channel).last?.id
        if keyboardOverlap > 0,
           newestMessageID != lastRenderedMessageID,
           lastRenderedMessageID != nil,
           isNearLatestWindow() {
            stickToLatestAfterNextReload = true
        }
        reloadTimeline(animated: true)
    }

    func reloadTimeline(animated: Bool) {
        guard timelineController != nil else { return }
        timelineController.updatePresentation(makeTimelinePresentation())
        timelineController.browsingHistoricalWindow = !isNearLatestWindow()
        let messages = store.messages(for: channel)
        timelineController.reload(messages: messages, activity: nil, animated: animated)
        lastRenderedMessageID = messages.last?.id
        updateJumpToBottomVisibility(animated: animated)
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
        let previousCount = store.messages(for: channel).count
        timelineController.captureBoundaryAnchor()
        Task { [weak self] in
            guard let self else { return }
            await store.loadOlderAsync(channel)
            if store.messages(for: channel).count == previousCount {
                timelineController.refreshControl.endRefreshing()
            }
            isHistoryRefreshing = false
            updateJumpToBottomVisibility(animated: true)
        }
    }

    func handleNewerRefresh() {
        guard !isNewerRefreshing,
              !store.isLoadingNewer(channel),
              !store.messages(for: channel).isEmpty else { return }
        isNewerRefreshing = true
        timelineController.captureVisibleAnchor()
        bottomRefreshIndicator.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            await store.loadNewerAsync(channel)
            if isNearLatestWindow() {
                timelineController.browsingHistoricalWindow = false
            }
            isNewerRefreshing = false
            bottomRefreshIndicator.stopAnimating()
            updateJumpToBottomVisibility(animated: true)
        }
    }

    func updateJumpToBottomVisibility(animated: Bool) {
        guard jumpToBottomBackground.superview != nil else { return }
        let visible = timelineController.hasInitialPosition && timelineController.shouldShowJumpToLatest
        let changes = { self.jumpToBottomBackground.alpha = visible ? 1 : 0 }
        if visible { jumpToBottomBackground.isHidden = false }
        let completion: (Bool) -> Void = { _ in
            if !visible { self.jumpToBottomBackground.isHidden = true }
        }
        if animated {
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

    func timelineDidTapRetry(cell: ChatNativeMessageCell, message: ChatMessage) {
        retry(message)
    }

    func timelineDidTapTranscript(message: ChatMessage) {
        handleTranscriptTap(message)
    }

    func timelineDidCorrectTranscript(message: ChatMessage) {
        presentTranscriptCorrection(message)
    }
}

extension ChatViewController {
    func toggleVoicePlayback(_ message: ChatMessage) {
        guard let url = message.mediaURL else { return }
        if playingVoiceMessageID == message.id {
            stopVoicePlayback()
            return
        }
        stopVoicePlayback(deactivateSession: false)
        let session = AVAudioSession.sharedInstance()
        do {
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
            Task { @MainActor [weak self] in self?.stopVoicePlayback() }
        }
        voicePlaybackTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self,
                      playingVoiceMessageID == message.id,
                      let duration = voicePlayer?.currentItem?.duration.seconds,
                      duration.isFinite,
                      duration > 0 else { return }
                playingVoiceProgress = min(1, max(0, CGFloat(time.seconds / duration)))
                updateVoiceMessageCell(message.id, isPlaying: true)
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
        guard let indexPath = timelineController.indexPath(forMessageId: id),
              collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
        (collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell)?
            .setVoicePlayback(progress: playingVoiceProgress, isPlaying: isPlaying)
    }
}
