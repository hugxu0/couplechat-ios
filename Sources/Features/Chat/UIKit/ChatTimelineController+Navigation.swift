import UIKit

extension ChatTimelineController {
    func captureBoundaryAnchor() {
        pendingTopAnchor = dragStartAnchor ?? visibleAnchor()
    }

    func captureVisibleAnchor() {
        pendingTopAnchor = dragStartAnchor ?? visibleAnchor()
    }

    func captureDragStartAnchor() {
        dragStartAnchor = visibleAnchor()
    }

    func scrollToMessage(id: String, highlighted: Bool) {
        guard let indexPath = indexPath(forMessageId: id) else { return }
        highlightedMessageId = highlighted ? id : nil
        collectionView.reloadItems(at: [indexPath])
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
        guard highlighted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, highlightedMessageId == id else { return }
            highlightedMessageId = nil
            if let path = self.indexPath(forMessageId: id) {
                collectionView.reloadItems(at: [path])
            }
        }
    }

    func scrollToBottom(animated: Bool) {
        guard !items.isEmpty else { return }
        collectionView.layoutIfNeeded()
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(
            minY,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: maxY), animated: animated)
    }

    func isNearBottom() -> Bool {
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom
        return collectionView.contentOffset.y >= maxOffset - 44
    }

    func isNearLatestWindow() -> Bool { !browsingHistoricalWindow }

    func sourceView(for identifier: String) -> UIView? {
        for case let cell as ChatNativeMessageCell in collectionView.visibleCells {
            if let source = cell.mediaTransitionSourceView(for: identifier) { return source }
        }
        return nil
    }
}
