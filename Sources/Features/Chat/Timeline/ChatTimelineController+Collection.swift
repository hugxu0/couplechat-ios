import UIKit

extension ChatTimelineController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let item = items[indexPath.item]
        switch item {
        case .time(_, let text):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatTimeCell.reuseId,
                for: indexPath) as! ChatTimeCell
            cell.configure(text: text, usesLightContent: presentation.timelineUsesLightContent)
            return cell
        case .system(let itemId, let text):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatSystemCell.reuseId,
                for: indexPath) as! ChatSystemCell
            let recalledMessageId = reeditMessageIdsByItemId[itemId]
            cell.configure(
                text: text,
                showsReedit: recalledMessageId != nil,
                accentColor: presentation.accentColor) { [weak self] in
                    guard let self, let recalledMessageId else { return }
                    self.delegate?.timelineDidRequestReedit(recalledMessageId: recalledMessageId)
                }
            return cell
        case .message(let id):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatNativeMessageCell.reuseId,
                for: indexPath) as! ChatNativeMessageCell
            guard let message = messagesById[id] else { return cell }
            let mine = message.sender == presentation.currentUsername
            cell.delegate = self
            cell.configure(
                message: message,
                mine: mine,
                groupedWithPrevious: groupedMessageIds.contains(message.id),
                read: presentation.partnerHasRead(message),
                highlighted: highlightedMessageId == message.id,
                peerAvatar: presentation.avatarText(message.sender),
                myAvatar: presentation.myAvatar,
                peerAvatarURL: presentation.avatarURL(message.sender),
                myAvatarURL: presentation.myAvatarURL,
                counterpartName: presentation.counterpartName,
                accentColor: presentation.accentColor,
                usesDarkIncomingBubble: presentation.usesDarkIncomingBubble,
                voicePlaying: presentation.playingVoiceMessageID == message.id,
                voiceProgress: presentation.playingVoiceMessageID == message.id
                    ? presentation.playingVoiceProgress : 0,
                transcript: voiceTranscripts[message.id],
                transcriptExpanded: expandedTranscriptIDs.contains(message.id))
            return cell
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard indexPath.item < items.count else { return .zero }
        let width = collectionView.bounds.width
        switch items[indexPath.item] {
        case .time:
            return CGSize(width: width, height: 40)
        case .system(_, let text):
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: width - 48, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.systemFont(ofSize: 12)],
                context: nil)
            return CGSize(width: width, height: max(32, ceil(rect.height) + 16))
        case .message(let id):
            guard let message = messagesById[id] else { return CGSize(width: width, height: 1) }
            let grouped = groupedMessageIds.contains(message.id)
            let key = ChatMessageLayout.key(
                message: message,
                width: width,
                mine: message.sender == presentation.currentUsername,
                groupedWithPrevious: grouped,
                highlighted: highlightedMessageId == message.id,
                transcript: voiceTranscripts[message.id],
                transcriptExpanded: expandedTranscriptIDs.contains(message.id))
            if let cached = layoutHeightCache[key] { return CGSize(width: width, height: cached) }
            let height = ChatTimelineMetrics.messageHeight(
                for: message,
                containerWidth: width,
                groupedWithPrevious: grouped,
                transcript: voiceTranscripts[message.id],
                transcriptExpanded: expandedTranscriptIDs.contains(message.id))
            layoutHeightCache[key] = height
            return CGSize(width: width, height: height)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard indexPath.item < items.count,
              case .message(let id) = items[indexPath.item],
              let message = messagesById[id],
              !message.pending,
              !message.failed else { return }
        delegate?.timelineDidDisplay(message)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        completeFollowingLatest()
        captureDragStartAnchor()
        delegate?.timelineDidBeginDragging()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        completeFollowingLatest()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        _ = ChatScrollReducer.reduce(
            state: &scrollState,
            event: .userScrolled(isNearBottom: isNearBottom(), isAtLatestWindow: isNearLatestWindow()))
        delegate?.timelineDidScroll()
        let bottomPull = scrollView.contentOffset.y + scrollView.bounds.height
            - scrollView.contentInset.bottom - scrollView.contentSize.height
        if scrollView.isDragging, bottomPull > 48, !isNearLatestWindow() {
            delegate?.timelineDidRequestNewer()
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        // 首次进入聊天时，时间线可能还有一次异步的“贴到最新”校正。
        // 长按前先结束校正并固化布局，避免系统预览与背后的 cell 使用两套坐标。
        completeFollowingLatest()
        collectionView.layer.removeAllAnimations()
        collectionView.layoutIfNeeded()
        guard let message = contextMenuMessage(at: indexPath, point: point) else { return nil }
        return UIContextMenuConfiguration(identifier: message.id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: self.menuActions(for: message))
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        targetedPreview(configuration)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        targetedPreview(configuration)
    }

    private func contextMenuMessage(at indexPath: IndexPath, point: CGPoint) -> ChatMessage? {
        guard indexPath.item < items.count else { return nil }
        switch items[indexPath.item] {
        case .message(let id):
            guard !id.hasPrefix("__ai_activity__"),
                  let message = messagesById[id],
                  let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell else { return nil }
            let converted = collectionView.convert(point, to: cell)
            return cell.containsBubble(point: point) || cell.containsBubble(point: converted) ? message : nil
        case .system(let systemID, _):
            let id = systemID.hasPrefix("system-") ? String(systemID.dropFirst("system-".count)) : ""
            return messagesById[id]
        default:
            return nil
        }
    }

    private func menuActions(for message: ChatMessage) -> [UIAction] {
        ChatMessageActionProvider.actions(
            for: message,
            currentUsername: presentation.currentUsername).map { action in
            let attributes: UIMenuElement.Attributes = action == .recall || action == .discard ? .destructive : []
            return UIAction(
                title: title(for: action),
                image: UIImage(systemName: icon(for: action)),
                attributes: attributes
            ) { [weak self] _ in
                self?.delegate?.timelineDidSelect(action, message: message)
            }
        }
    }

    private func title(for action: ChatMessageAction) -> String {
        switch action {
        case .copy: return "复制"
        case .reply: return "引用"
        case .addToAlbum: return "加入共同相册"
        case .recall: return "撤回"
        case .retry: return "重新发送"
        case .discard: return "删除"
        }
    }

    private func icon(for action: ChatMessageAction) -> String {
        switch action {
        case .copy: return "doc.on.doc"
        case .reply: return "arrowshape.turn.up.left"
        case .addToAlbum: return "photo.badge.plus"
        case .recall, .discard: return "trash"
        case .retry: return "arrow.clockwise"
        }
    }

    private func targetedPreview(_ configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let id = configuration.identifier as? String,
              let indexPath = indexPath(forMessageId: id),
              let cell = collectionView.cellForItem(at: indexPath) as? ChatNativeMessageCell else { return nil }
        collectionView.layoutIfNeeded()
        cell.layoutIfNeeded()
        return cell.bubbleTargetedPreview(in: collectionView)
    }

}

extension ChatTimelineController: ChatTimelineCellDelegate {
    func chatCellDidDecideConfirm(_ cell: ChatNativeMessageCell, decision: String) {
        guard let path = collectionView.indexPath(for: cell), path.item < items.count,
              case .message(let id) = items[path.item], let message = messagesById[id] else { return }
        delegate?.timelineDidDecideConfirm(message: message, decision: decision)
    }

    func chatCellDidTapMedia(_ cell: ChatNativeMessageCell) {
        guard let path = collectionView.indexPath(for: cell), path.item < items.count,
              case .message(let id) = items[path.item], let message = messagesById[id] else { return }
        delegate?.timelineDidTapMedia(
            cell: cell,
            message: message,
            selectedId: cell.selectedMediaIdentifier ?? id)
    }

    func chatCellDidTapRetry(_ cell: ChatNativeMessageCell) {
        guard let path = collectionView.indexPath(for: cell), path.item < items.count,
              case .message(let id) = items[path.item], let message = messagesById[id] else { return }
        delegate?.timelineDidTapRetry(cell: cell, message: message)
    }

    func chatCellDidTapTranscript(_ cell: ChatNativeMessageCell) {
        guard let message = message(for: cell) else { return }
        delegate?.timelineDidTapTranscript(message: message)
    }

    func chatCellDidTapTranscriptCorrection(_ cell: ChatNativeMessageCell) {
        guard let message = message(for: cell) else { return }
        delegate?.timelineDidCorrectTranscript(message: message)
    }

    private func message(for cell: ChatNativeMessageCell) -> ChatMessage? {
        guard let path = collectionView.indexPath(for: cell), path.item < items.count,
              case .message(let id) = items[path.item] else { return nil }
        return messagesById[id]
    }
}
