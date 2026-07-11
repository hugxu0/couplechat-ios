import AVFoundation
import Combine
import UIKit

extension ChatViewController {
    func bindStore() {
        cancellables.removeAll()
        messageStore.$messagesByChannel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.handleStoreChange() }
            .store(in: &cancellables)

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    composer.setTypingVisible(false)
                    composer.setCatThinking(store.isAIComposing(in: channel))
                    reloadTimeline(animated: true)
                }
            }
            .store(in: &cancellables)
    }

    func handleStoreChange() {
        composer.setTypingVisible(false)
        composer.setCatThinking(store.isAIComposing(in: channel))
        reloadTimeline(animated: true)
        store.markRead(channel)
    }

    func reloadTimeline(animated: Bool) {
        guard timelineController != nil else { return }
        timelineController.updatePresentation(makeTimelinePresentation())
        timelineController.browsingHistoricalWindow = !isNearLatestWindow()
        timelineController.reload(
            messages: store.messages(for: channel),
            activity: aiActivityMessage(),
            animated: animated)
        updateJumpToBottomVisibility(animated: animated)
    }

    func aiActivityMessage() -> ChatMessage? {
        guard let activity = store.aiActivity(for: channel), activity.isVisible else { return nil }
        return ChatMessage(dict: [
            "id": "__ai_activity__\(channel.rawValue)",
            "sender": "ai",
            "senderName": "大橘",
            "kind": "user",
            "type": "text",
            "text": "大橘正在输入…",
            "channel": channel.rawValue,
            "ts": Date().timeIntervalSince1970 * 1_000,
        ])
    }

    func isNearLatestWindow() -> Bool {
        guard let currentLast = store.messages(for: channel).last else { return true }
        let latest = ChatLocalDatabase.shared
            .fetchLatestMessages(channel: channel.rawValue, limit: 1)
            .last
        return latest?.id == currentLast.id
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
            await store.loadOlderAsync(channel)
            reloadTimeline(animated: false)
            timelineController.refreshControl.endRefreshing()
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
            reloadTimeline(animated: false)
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
            Task { await store.discardFailedMessage(message) }
        })
        present(alert, animated: true)
    }

    func presentMedia(message: ChatMessage, selectedId: String) {
        if message.type == "voice" {
            toggleVoicePlayback(message)
        } else if message.type == "file", let url = message.mediaURL {
            UIApplication.shared.open(url)
        } else {
            let items = Array(store.mediaMessages(for: channel, includeFiles: false).reversed())
                .flatMap(MediaBrowserItem.items(for:))
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

extension ChatViewController: ChatTimelineControllerDelegate {
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

    func timelineDidSelect(_ action: ChatMessageAction, message: ChatMessage) {
        switch action {
        case .copy:
            UIPasteboard.general.string = message.displayText
        case .reply:
            setReplyTarget(message)
        case .recall:
            store.recallMessage(message, channel: channel)
        case .reedit:
            beginEditingRecalledMessage(message)
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
