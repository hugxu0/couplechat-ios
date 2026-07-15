import UIKit

extension ChatViewController {
    func refreshComposerSurfaceTone(force: Bool = false) {
        guard dynamicallySamplesComposerTone,
              view.bounds.width > 0,
              view.bounds.height > 0 else { return }
        let capsuleFrame = composer.inputCapsuleFrame(in: view).integral
        guard !capsuleFrame.isEmpty, !capsuleFrame.isNull else { return }
        guard force || !capsuleFrame.equalTo(lastComposerSampleFrame) else { return }
        lastComposerSampleFrame = capsuleFrame
        let samplingFrame = capsuleFrame.insetBy(dx: 12, dy: 6)
        let normalizedFrame = CGRect(
            x: samplingFrame.minX / view.bounds.width,
            y: samplingFrame.minY / view.bounds.height,
            width: samplingFrame.width / view.bounds.width,
            height: samplingFrame.height / view.bounds.height)
        guard let luminance = theme.customWallpaperLuminance(
            for: channel,
            normalizedRect: normalizedFrame) else { return }
        let usesLightContent = ChatSurfaceTone(luminance: luminance).usesLightContent
        guard composerUsesLightContent != usesLightContent else { return }
        composerUsesLightContent = usesLightContent
        bottomDockBackground.setGlassTone(
            dark: usesLightContent,
            tintAlpha: usesLightContent ? 0.08 : 0.06,
            borderAlpha: 0)
        composer.applyTheme(theme, usesLightContent: usesLightContent)
        stickerPanel?.applyTheme(
            accentColor: theme.accent.uiColor,
            usesLightContent: usesLightContent)
    }

    func installStickerPanel() {
        let panel = ChatStickerPanelView(store: StickerStore.shared, accentColor: theme.accent.uiColor)
        panel.applyTheme(accentColor: theme.accent.uiColor, usesLightContent: composerUsesLightContent)
        panel.delegate = self
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelContainer.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: panelContainer.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: panelContainer.trailingAnchor),
            panel.topAnchor.constraint(equalTo: panelContainer.topAnchor),
            panel.bottomAnchor.constraint(equalTo: panelContainer.bottomAnchor),
        ])
        stickerPanel = panel
    }

    func configureKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardNotification(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardNotification(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRecallFailure),
            name: MessageStore.recallFailedNotification,
            object: nil)
    }

    @objc func handleRecallFailure() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "撤回失败",
            message: "消息已恢复，请检查连接后重试。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    @objc func handleKeyboardNotification(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25
        let rawCurve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
            .uintValue ?? UIView.AnimationOptions.curveEaseOut.rawValue
        let curve = UIView.AnimationOptions(rawValue: rawCurve << 16)
        let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let frameInView = view.convert(endFrame, from: view.window)
        let overlap = max(0, view.bounds.maxY - frameInView.minY)
        let keyboardIsAppearing = overlap > keyboardOverlap + 0.5
        if overlap > 0 { lastVisibleKeyboardOverlap = overlap }
        let isReplacingInputSurface = panelHeightConstraint.constant > 0
        if overlap > 0, isReplacingInputSurface,
           case .emojiPanel = inputState {
            // 表情面板正在接管键盘空间，忽略键盘尚未完全落下时的中间帧。
            return
        }
        if keyboardTransitionMaintainsLatest == nil {
            // 编辑开始时本来就会回到最新；即使 keyboardLayoutGuide 已抢先改变了
            // 一帧几何，也不能因此丢掉贴底意图。收起键盘时则尊重用户是否已上滑。
            keyboardTransitionMaintainsLatest = !timelineController.browsingHistoricalWindow
                && (timelineController.maintainsLatestPosition
                    || (keyboardIsAppearing && composer.textView.isFirstResponder))
        }
        keyboardTransitionGeneration += 1
        let transitionGeneration = keyboardTransitionGeneration
        keyboardLayoutAnimationActive = true
        keyboardOverlap = overlap
        if overlap > 0, isReplacingInputSurface {
            panelHeightConstraint.constant = 0
            panelContainer.isHidden = true
            updateBottomDockAnchor(usesScreenBottom: false)
            composer.setStickerPanelVisible(false)
        }
        applyInputLayout(
            duration: duration,
            curve: curve,
            forceBottom: !isReplacingInputSurface,
            keyboardTransitionGeneration: transitionGeneration)
    }

    func applyInputLayout(
        duration: TimeInterval,
        curve: UIView.AnimationOptions,
        forceBottom: Bool = false,
        keyboardTransitionGeneration transitionGeneration: Int? = nil
    ) {
        guard timelineController != nil else { return }
        let isUserScrolling = collectionView.isTracking
            || collectionView.isDragging
            || collectionView.isDecelerating
        // collectionView 的底边已直接约束在 bottomStack 上方。这里保留的是
        // 用户布局变化前的“逻辑跟随最新”状态，而不是用变化后的几何再猜一次。
        let shouldMaintainLatest = keyboardTransitionMaintainsLatest
            ?? timelineController.maintainsLatestPosition
        let shouldForceLatest = forceBottom
            && !timelineController.browsingHistoricalWindow
            && shouldMaintainLatest
        let anchor = shouldMaintainLatest || shouldForceLatest
            ? nil
            : timelineController.visibleAnchor()

        let updates = {
            if !self.bottomDockUsesScreenBottom {
                self.bottomConstraint.constant = -(
                    self.inputDockSpacing + max(self.keyboardOverlap, self.view.safeAreaInsets.bottom))
            }
            self.view.layoutIfNeeded()
            self.timelineController.setInsets(top: self.topOverlayInset, bottom: 0)
            self.collectionView.layoutIfNeeded()
            if (shouldMaintainLatest || shouldForceLatest) && !isUserScrolling {
                self.timelineController.scrollToBottom(animated: false)
            } else if let anchor, !isUserScrolling {
                self.timelineController.restore(anchor)
            }
            self.updateJumpToBottomVisibility(animated: duration > 0)
        }
        guard duration > 0 else {
            UIView.performWithoutAnimation(updates)
            if transitionGeneration == keyboardTransitionGeneration {
                keyboardTransitionMaintainsLatest = nil
                keyboardLayoutAnimationActive = false
            }
            return
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [curve, .beginFromCurrentState, .allowUserInteraction],
            animations: updates,
            completion: { [weak self] _ in
                guard let self else { return }
                // 动画结束后使用最终 frame 再校准一次；duration=0 不会递归动画。
                self.applyInputLayout(duration: 0, curve: .curveEaseOut)
                self.timelineController.settleFollowingLatestIfNeeded()
                if transitionGeneration == self.keyboardTransitionGeneration {
                    self.keyboardTransitionMaintainsLatest = nil
                    self.keyboardLayoutAnimationActive = false
                }
            })
    }

    func setReplyTarget(_ message: ChatMessage) {
        replyTarget = message
        composer.setReplyPreview(message.replyPreviewText)
        composer.focusTextInput()
    }

    func clearReplyTarget() {
        replyTarget = nil
        composer.setReplyPreview(nil)
    }

    func sendText(_ text: String) {
        let target = replyTarget
        clearReplyTarget()
        composer.clearText()
        stickToLatestAfterNextReload = true
        store.sendText(
            text,
            channel: channel,
            replyTo: target?.id,
            replyPreview: target?.replyPreviewText)
        reloadTimeline(animated: false)
        hidePanel(animated: true)
    }

    func sendSticker(_ sticker: Sticker) {
        Haptics.light()
        stickToLatestAfterNextReload = true
        store.sendSticker(url: sticker.url, channel: channel)
        reloadTimeline(animated: false)
    }

    func summonDaju() {
        let textView = composer.textView
        if !(textView.text ?? "").contains("@大橘") {
            textView.text = textView.text.isEmpty ? "@大橘 " : "@大橘 " + textView.text
            composer.textViewDidChange(textView)
        }
        composer.focusTextInput()
    }

    func toggleStickerPanel() {
        if panelHeightConstraint.constant > 0 {
            inputState = .editing
            composer.setStickerPanelVisible(false)
            // 先让系统键盘升起并占住同一块空间；键盘通知到达后再撤掉面板，
            // 输入栏不会经历一次落到底部再弹回来的过程。
            composer.focusTextInput()
        } else {
            showPanel(height: 300)
        }
    }

    func showPanel(height: CGFloat) {
        let replacingKeyboard = keyboardOverlap > view.safeAreaInsets.bottom + 1
            || composer.textView.isFirstResponder
        let replacementHeight = max(height, max(keyboardOverlap, lastVisibleKeyboardOverlap)) + 8
        inputState = .emojiPanel
        panelContainer.isHidden = false
        panelHeightConstraint.constant = replacementHeight
        updateBottomDockAnchor(usesScreenBottom: true)
        composer.setStickerPanelVisible(true)
        applyInputLayout(
            duration: replacingKeyboard ? 0 : 0.24,
            curve: .curveEaseOut,
            forceBottom: !replacingKeyboard)
        composer.resignTextInput()
        keyboardOverlap = 0
    }

    func hidePanel(animated: Bool) {
        guard panelHeightConstraint.constant > 0 else { return }
        panelHeightConstraint.constant = 0
        panelContainer.isHidden = true
        updateBottomDockAnchor(usesScreenBottom: false)
        composer.setStickerPanelVisible(false)
        if case .emojiPanel = inputState { inputState = .idle }
        applyInputLayout(
            duration: animated ? 0.2 : 0,
            curve: .curveEaseOut,
            forceBottom: true)
    }

    func dismissInput(animated: Bool) {
        composer.resignTextInput()
        hidePanel(animated: animated)
        inputState = .idle
    }

    private func updateBottomDockAnchor(usesScreenBottom: Bool) {
        bottomDockUsesScreenBottom = usesScreenBottom
        bottomConstraint.isActive = false
        bottomConstraint = usesScreenBottom
            ? bottomStack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            : bottomStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -(
                    inputDockSpacing + max(keyboardOverlap, view.safeAreaInsets.bottom)))
        bottomConstraint.isActive = true
    }

    @objc func handleCollectionTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: point),
           let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell {
            let localPoint = collectionView.convert(point, to: cell)
            if cell.containsBubble(point: localPoint) { return }
        }
        dismissInput(animated: true)
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

}

extension ChatViewController: ChatComposerViewDelegate {
    func composerDidSendText(_ text: String) { sendText(text) }
    func composerDidTapCat() { summonDaju() }
    func composerDidTapEmoji() { toggleStickerPanel() }
    func composerDidTapAttachment() { showAttachmentMenu() }
    func composerDidTapSendMedia() { sendPendingMedia() }

    func composerDidRemoveMedia(id: String) {
        pendingMedia.removeAll { $0.id == id }
        composer.setMediaPreviews(pendingMedia)
    }

    func composerDidCancelReply() { clearReplyTarget() }

    func composerTextDidBeginEditing() {
        let replacingPanel = panelHeightConstraint.constant > 0
        inputState = .editing
        composer.setStickerPanelVisible(false)
        if !replacingPanel, !timelineController.browsingHistoricalWindow {
            timelineController.scrollToBottom(animated: true)
        }
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
