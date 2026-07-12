import Foundation

enum ChatMessageAction: Equatable {
    case copy
    case reply
    case addToAlbum
    case recall
    case retry
    case discard
}

enum ChatMessageActionProvider {
    static func actions(
        for message: ChatMessage,
        currentUsername: String?,
        nowMilliseconds: Double = Date().timeIntervalSince1970 * 1_000
    ) -> [ChatMessageAction] {
        if message.kind == "system" { return [] }
        if message.failed { return [.retry, .discard] }
        if message.pending { return [] }

        var actions: [ChatMessageAction] = []
        if message.type == "text" { actions.append(.copy) }
        actions.append(.reply)
        if message.channel == "couple", message.type == "image" || message.type == "video" {
            actions.append(.addToAlbum)
        }
        if message.sender == currentUsername, nowMilliseconds - message.ts < 120_000 {
            actions.append(.recall)
        }
        return actions
    }
}
