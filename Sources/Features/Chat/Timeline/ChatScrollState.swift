import Foundation

struct ChatScrollState: Equatable {
    var didInitialPosition = false
    var isNearBottom = true
    var isAtLatestWindow = true
    var hasNewMessagesBelow = false
    var isLoadingOlder = false
    var isLoadingNewer = false
}

enum ChatScrollEvent: Equatable {
    case initialContent
    case receivedMessage(isMine: Bool)
    case loadedOlder
    case loadedNewer(reachedLatest: Bool)
    case jumpedToMessage
    case userScrolled(isNearBottom: Bool, isAtLatestWindow: Bool)
}

enum ChatScrollCommand: Equatable {
    case scrollToLatest(animated: Bool)
    case preserveAnchor
    case preservePosition
    case showJumpToLatest(Bool)
}

enum ChatScrollReducer {
    static func reduce(state: inout ChatScrollState, event: ChatScrollEvent) -> [ChatScrollCommand] {
        switch event {
        case .initialContent:
            guard !state.didInitialPosition else { return [.preservePosition] }
            state.didInitialPosition = true
            state.hasNewMessagesBelow = false
            return [.scrollToLatest(animated: false)]
        case .receivedMessage(let isMine):
            let shouldFollowLatest = isMine || (state.isNearBottom && state.isAtLatestWindow)
            state.hasNewMessagesBelow = !shouldFollowLatest
            return shouldFollowLatest
                ? [.scrollToLatest(animated: true)]
                : [.showJumpToLatest(true)]
        case .loadedOlder:
            state.isLoadingOlder = false
            return [.preserveAnchor]
        case .loadedNewer(let reachedLatest):
            state.isLoadingNewer = false
            state.isAtLatestWindow = reachedLatest
            if reachedLatest { state.hasNewMessagesBelow = false }
            return reachedLatest ? [.scrollToLatest(animated: false)] : [.preserveAnchor]
        case .jumpedToMessage:
            state.isNearBottom = false
            return [.showJumpToLatest(true)]
        case .userScrolled(let isNearBottom, let isAtLatestWindow):
            state.isNearBottom = isNearBottom
            state.isAtLatestWindow = isAtLatestWindow
            if isNearBottom && isAtLatestWindow {
                state.hasNewMessagesBelow = false
            }
            return [.showJumpToLatest(!(isNearBottom && isAtLatestWindow))]
        }
    }
}
