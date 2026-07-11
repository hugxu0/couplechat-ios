import UIKit

@MainActor
protocol ChatTimelineControllerDelegate: AnyObject {
    func timelineDidBeginDragging()
    func timelineDidScroll()
    func timelineDidRequestOlder()
    func timelineDidRequestNewer()
    func timelineDidSelect(_ action: ChatMessageAction, message: ChatMessage)
    func timelineDidTapMedia(cell: ChatNativeMessageCell, message: ChatMessage, selectedId: String)
    func timelineDidTapRetry(cell: ChatNativeMessageCell, message: ChatMessage)
}

@MainActor
final class ChatTimelineController: NSObject {
    struct Presentation {
        var currentUsername: String?
        var counterpartName: String
        var myAvatar: String
        var myAvatarURL: URL?
        var accentColor: UIColor
        var usesDarkIncomingBubble: Bool
        var timelineUsesLightContent: Bool
        var playingVoiceMessageID: String?
        var playingVoiceProgress: CGFloat
        var avatarText: (String) -> String
        var avatarURL: (String) -> URL?
        var partnerHasRead: (ChatMessage) -> Bool
    }

    weak var delegate: ChatTimelineControllerDelegate?
    let collectionView: UICollectionView
    let refreshControl = UIRefreshControl()
    var presentation: Presentation
    var items: [ChatTimelineItem] = []
    var messagesById: [String: ChatMessage] = [:]
    var groupedMessageIds = Set<String>()
    var layoutHeightCache: [ChatMessageLayout: CGFloat] = [:]
    var highlightedMessageId: String?
    var pendingTopAnchor: (itemId: String, offset: CGFloat)?
    var dragStartAnchor: (itemId: String, offset: CGFloat)?
    var stickToLatestAfterNextReload = false
    var scrollState = ChatScrollState()
    private var suppressesJumpToLatest = false
    private var followLatestGeneration = 0
    var topInset: CGFloat = 96
    var bottomInset: CGFloat = 0
    private var lastMeasuredWidth: CGFloat = 0

    init(presentation: Presentation) {
        self.presentation = presentation
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        layout.estimatedItemSize = .zero
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        configureCollectionView()
    }

    func updatePresentation(_ presentation: Presentation) {
        self.presentation = presentation
    }

    func reload(messages: [ChatMessage], activity: ChatMessage?, animated: Bool) {
        let oldFirstMessageID = items.compactMap { item -> String? in
            if case .message(let id) = item { return id }
            return nil
        }.first
        let wasNearLatestBottom = isNearBottom() && isNearLatestWindow()
        let oldAnchor = visibleAnchor()
        let wasShowingActivity = items.contains { $0.id.hasPrefix("__ai_activity__") }
        let oldLast = lastMessageId(in: items)
        let oldCount = messageCount(in: items)
        let result = ChatTimelineBuilder.build(messages: messages, activity: activity)
        items = result.items
        messagesById = result.messagesById
        groupedMessageIds = result.groupedMessageIds

        if pendingTopAnchor != nil,
           let oldFirstMessageID,
           let boundary = messages.firstIndex(where: { $0.id == oldFirstMessageID }),
           boundary > messages.startIndex {
            let newestLoadedMessage = messages[messages.index(before: boundary)]
            pendingTopAnchor = (newestLoadedMessage.id, topInset + 8)
        }

        if refreshControl.isRefreshing, pendingTopAnchor != nil {
            UIView.performWithoutAnimation {
                refreshControl.endRefreshing()
                collectionView.layoutIfNeeded()
            }
        }

        let reload = {
            self.collectionView.reloadData()
            self.collectionView.layoutIfNeeded()
        }
        if animated {
            reload()
        } else {
            UIView.performWithoutAnimation(reload)
        }

        let decision = ChatTimelineReloadDecision.decide(
            stickToLatest: stickToLatestAfterNextReload,
            hasPendingAnchor: pendingTopAnchor != nil,
            hasValidPendingAnchor: pendingTopAnchor.map { indexPath(forItemId: $0.itemId) != nil } ?? false,
            hasValidVisibleAnchor: oldAnchor.map { indexPath(forItemId: $0.itemId) != nil } ?? false,
            wasNearLatestBottom: wasNearLatestBottom,
            lastMessageChanged: oldLast != lastMessageId(in: items),
            messageCountIncreased: messageCount(in: items) > oldCount,
            wasShowingAIActivity: wasShowingActivity)
        execute(decision, oldAnchor: oldAnchor, animated: animated)
        scheduleInitialPositioning()
    }

    var browsingHistoricalWindow: Bool {
        get { !scrollState.isAtLatestWindow }
        set { scrollState.isAtLatestWindow = !newValue }
    }

    var hasInitialPosition: Bool { scrollState.didInitialPosition }

    var shouldShowJumpToLatest: Bool {
        !suppressesJumpToLatest && !(isNearBottom() && isNearLatestWindow())
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        topInset = top
        bottomInset = bottom
        collectionView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        collectionView.scrollIndicatorInsets = collectionView.contentInset
    }

    func invalidateLayoutIfNeeded() {
        let width = floor(collectionView.bounds.width)
        guard width > 0, abs(width - lastMeasuredWidth) > 0.5 else { return }
        lastMeasuredWidth = width
        layoutHeightCache.removeAll()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func invalidateAppearance() {
        layoutHeightCache.removeAll()
        collectionView.collectionViewLayout.invalidateLayout()
        UIView.performWithoutAnimation {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
        }
    }

    func scheduleInitialPositioning() {
        guard !scrollState.didInitialPosition,
              !items.isEmpty,
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0,
              bottomInset > 0 else { return }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        let commands = ChatScrollReducer.reduce(state: &scrollState, event: .initialContent)
        execute(commands)
        collectionView.alpha = 1
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alpha = 0
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ChatTimeCell.self, forCellWithReuseIdentifier: ChatTimeCell.reuseId)
        collectionView.register(ChatSystemCell.self, forCellWithReuseIdentifier: ChatSystemCell.reuseId)
        collectionView.register(ChatNativeMessageCell.self, forCellWithReuseIdentifier: ChatNativeMessageCell.reuseId)
        refreshControl.tintColor = .white
        refreshControl.transform = CGAffineTransform(scaleX: 0.72, y: 0.72)
        refreshControl.addAction(UIAction { [weak self] _ in self?.delegate?.timelineDidRequestOlder() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
    }

    private func execute(
        _ decision: ChatTimelineReloadDecision,
        oldAnchor: (itemId: String, offset: CGFloat)?,
        animated: Bool
    ) {
        switch decision {
        case .forceLatest:
            stickToLatestAfterNextReload = false
            browsingHistoricalWindow = false
            followLatest(animated: false)
        case .restorePendingAnchor:
            if let anchor = pendingTopAnchor { restore(anchor) }
            pendingTopAnchor = nil
            dragStartAnchor = nil
        case .restoreVisibleAnchor:
            if let oldAnchor { restore(oldAnchor) }
        case .followLatest:
            followLatest(animated: animated)
        case .preservePosition:
            break
        }
    }

    func visibleAnchor() -> (itemId: String, offset: CGFloat)? {
        let visible = collectionView.indexPathsForVisibleItems.sorted {
            let lhs = collectionView.layoutAttributesForItem(at: $0)?.frame.minY ?? 0
            let rhs = collectionView.layoutAttributesForItem(at: $1)?.frame.minY ?? 0
            return lhs < rhs
        }
        guard let path = visible.first, path.item < items.count,
              let attributes = collectionView.layoutAttributesForItem(at: path) else { return nil }
        return (items[path.item].id, attributes.frame.minY - collectionView.contentOffset.y)
    }

    func restore(_ anchor: (itemId: String, offset: CGFloat)) {
        guard let path = indexPath(forItemId: anchor.itemId),
              let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
        setClampedContentOffsetY(frame.minY - anchor.offset)
    }

    func indexPath(forItemId id: String) -> IndexPath? {
        items.firstIndex(where: { $0.id == id }).map { IndexPath(item: $0, section: 0) }
    }

    func indexPath(forMessageId id: String) -> IndexPath? {
        items.firstIndex { if case .message(let value) = $0 { return value == id }; return false }
            .map { IndexPath(item: $0, section: 0) }
    }

    func setClampedContentOffsetY(_ targetY: CGFloat) {
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(max(targetY, minY), maxY)), animated: false)
    }

    private func lastMessageId(in items: [ChatTimelineItem]) -> String? {
        items.reversed().compactMap { if case .message(let id) = $0 { return id }; return nil }.first
    }

    private func messageCount(in items: [ChatTimelineItem]) -> Int {
        items.reduce(into: 0) { count, item in if case .message = item { count += 1 } }
    }

    private func execute(_ commands: [ChatScrollCommand]) {
        for command in commands {
            switch command {
            case .scrollToLatest(let animated):
                scrollToBottom(animated: animated)
            case .preserveAnchor:
                if let pendingTopAnchor { restore(pendingTopAnchor) }
                pendingTopAnchor = nil
            case .preservePosition, .showJumpToLatest:
                break
            }
        }
    }

    private func followLatest(animated: Bool) {
        followLatestGeneration += 1
        let generation = followLatestGeneration
        suppressesJumpToLatest = true
        scrollToBottom(animated: animated)
        guard !animated else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.followLatestGeneration == generation else { return }
            self.collectionView.layoutIfNeeded()
            self.scrollToBottom(animated: false)
            self.suppressesJumpToLatest = false
            self.delegate?.timelineDidScroll()
        }
    }

    func completeFollowingLatest() {
        guard suppressesJumpToLatest else { return }
        followLatestGeneration += 1
        suppressesJumpToLatest = false
        delegate?.timelineDidScroll()
    }
}
