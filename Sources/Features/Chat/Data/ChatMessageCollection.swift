import Foundation

/// 聊天消息数组的唯一合并入口。
///
/// 页面只观察最终数组；去重、乐观消息替换与时间排序都在这里完成，避免 Socket、
/// 历史分页和发送 ACK 各自维护一套略有差异的实现。
enum ChatMessageCollection {
    static func upsert(_ message: ChatMessage, into messages: inout [ChatMessage]) {
        if !isConfirmed(message),
           let confirmed = messages.first(where: {
               sameIdentity($0, message) && isConfirmed($0)
           }) {
            // 云端/SQLite 的正式消息是权威状态。启动恢复时，即使 outbox 清理曾被
            // 系统中断，也不能让随后投影的 pending 反向覆盖已经确认的消息。
            messages.removeAll { sameIdentity($0, message) }
            insertChronologically(confirmed, into: &messages)
            return
        }
        if messages.contains(where: { sameIdentity($0, message) }) {
            messages.removeAll { sameIdentity($0, message) }
            insertChronologically(message, into: &messages)
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
        upsert(incoming, into: &messages)
    }

    static func appendUnique<S: Sequence>(_ incoming: S, to messages: inout [ChatMessage])
    where S.Element == ChatMessage {
        upsert(incoming, into: &messages)
    }

    static func replacePending(
        clientId: String,
        with acknowledged: ChatMessage,
        in messages: inout [ChatMessage]
    ) {
        messages.removeAll { message in
            message.id == clientId ||
                message.clientId == clientId ||
                message.id == acknowledged.id ||
                (message.clientId != nil && message.clientId == acknowledged.clientId)
        }
        insertChronologically(acknowledged, into: &messages)
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

    private static func isConfirmed(_ message: ChatMessage) -> Bool {
        !message.pending && !message.failed
    }

    static func isOrderedBefore(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        lhs.ts < rhs.ts || (lhs.ts == rhs.ts && lhs.id < rhs.id)
    }

    private static func insertChronologically(
        _ message: ChatMessage,
        into messages: inout [ChatMessage]
    ) {
        let index = messages.firstIndex(where: { isOrderedBefore(message, $0) })
            ?? messages.endIndex
        messages.insert(message, at: index)
    }
}
