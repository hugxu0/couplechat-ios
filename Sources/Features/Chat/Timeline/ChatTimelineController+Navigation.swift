import UIKit

extension ChatTimelineController {
    func captureBoundaryAnchor() {
        pendingTopAnchor = dragStartAnchor ?? visibleAnchor()
    }

    func captureVisibleAnchor() {
        // 向下分页要固定触发加载这一刻的可视位置；dragStartAnchor 是本次手势
        // 刚开始时的位置，复用它会在追加消息后把用户拉回很远。
        pendingTopAnchor = visibleAnchor() ?? dragStartAnchor
    }

    func captureDragStartAnchor() {
        dragStartAnchor = visibleAnchor()
    }

    func scrollToMessage(id: String, highlighted: Bool) {
        guard let indexPath = indexPath(forMessageId: id) else { return }
        highlightedMessageId = highlighted ? id : nil
        collectionView.reloadItems(at: [indexPath])
        collectionView.layoutIfNeeded()
        // 顶栏（topInset）会盖住内容区上沿，用 scrollToItem(.centeredVertically) 在
        // 靠顶的消息上会被 clamp 到标题栏后面。改为手动把目标顶部对齐到顶栏下方留白，
        // 让命中的消息稳定落在可视区内。
        if let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame {
            let desiredTop = frame.minY - topInset - 12
            setClampedContentOffsetY(desiredTop)
        } else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        }
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
