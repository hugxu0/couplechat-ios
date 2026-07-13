import Foundation

/// 聊天消息数组的唯一合并入口。
///
/// 页面只观察最终数组；去重、乐观消息替换与时间排序都在这里完成，避免 Socket、
/// 历史分页和发送 ACK 各自维护一套略有差异的实现。
enum ChatMessageCollection {
    static func upsert(_ message: ChatMessage, into messages: inout [ChatMessage]) {
        if let index = messages.firstIndex(where: { sameIdentity($0, message) }) {
            messages[index] = message
            removeDuplicates(of: message, keeping: index, from: &messages)
            return
        }
        insertChronologically(message, into: &messages)
    }

    static func upsert<S: Sequence>(_ incoming: S, into messages: inout [ChatMessage])
    where S.Element == ChatMessage {
        for message in incoming {
            upsert(message, into: &messages)
        }
    }

    static func prependUnique<S: Sequence>(_ incoming: S, to messages: inout [ChatMessage])
    where S.Element == ChatMessage {
        let unique = incoming.filter { candidate in
            !messages.contains(where: { sameIdentity($0, candidate) })
        }
        messages.insert(contentsOf: unique, at: 0)
    }

    static func appendUnique<S: Sequence>(_ incoming: S, to messages: inout [ChatMessage])
    where S.Element == ChatMessage {
        for message in incoming where !messages.contains(where: { sameIdentity($0, message) }) {
            messages.append(message)
        }
    }

    static func replacePending(
        clientId: String,
        with acknowledged: ChatMessage,
        in messages: inout [ChatMessage]
    ) {
        let pendingIndex = index(matchingClientId: clientId, in: messages)
        messages.removeAll { message in
            message.id == acknowledged.id ||
                (message.clientId != nil && message.clientId == acknowledged.clientId)
        }
        if let pendingIndex {
            messages.insert(acknowledged, at: min(pendingIndex, messages.endIndex))
        } else {
            insertChronologically(acknowledged, into: &messages)
        }
    }

    static func removePending(clientId: String, from messages: inout [ChatMessage]) {
        messages.removeAll { message in
            message.id == clientId || message.clientId == clientId
        }
    }

    static func index(matchingClientId clientId: String, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex { $0.id == clientId || $0.clientId == clientId }
    }

    static func sameIdentity(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.id == rhs.id { return true }
        if let lhsClientId = lhs.clientId, lhsClientId == rhs.id { return true }
        if let rhsClientId = rhs.clientId, rhsClientId == lhs.id { return true }
        if let lhsClientId = lhs.clientId, let rhsClientId = rhs.clientId {
            return lhsClientId == rhsClientId
        }
        return false
    }

    private static func insertChronologically(
        _ message: ChatMessage,
        into messages: inout [ChatMessage]
    ) {
        let index = messages.firstIndex(where: { $0.ts > message.ts }) ?? messages.endIndex
        messages.insert(message, at: index)
    }

    private static func removeDuplicates(
        of message: ChatMessage,
        keeping keptIndex: Int,
        from messages: inout [ChatMessage]
    ) {
        for index in messages.indices.reversed()
        where index != keptIndex && sameIdentity(messages[index], message) {
            messages.remove(at: index)
        }
    }
}
