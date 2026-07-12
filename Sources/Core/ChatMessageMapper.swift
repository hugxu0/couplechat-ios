import Foundation

enum ChatMessageMapper {
    private static let lock = NSLock()
    private static var successCount = 0
    private static var failureCount = 0

    static func parse(_ dictionary: [String: Any], context: String = "") -> ChatMessage? {
        if let message = ChatMessage(dict: dictionary) {
            lock.withLock { successCount += 1 }
            return message
        }

        let count = lock.withLock {
            failureCount += 1
            return failureCount
        }
        let id = dictionary["id"] as? String ?? "?"
        let sender = dictionary["sender"] as? String ?? "?"
        let channel = dictionary["channel"] as? String ?? "?"
        let keys = dictionary.keys.joined(separator: ",")
        print("[ChatMessageMapper] ⚠️ 消息解析失败 #\(count) | id=\(id) sender=\(sender) channel=\(channel) context=\(context) keys=[\(keys)]")
        return nil
    }

    static func parse(_ rows: [[String: Any]], context: String = "") -> [ChatMessage] {
        let failuresBefore = lock.withLock { failureCount }
        let result = rows.compactMap { parse($0, context: context) }
        let failed = lock.withLock { failureCount - failuresBefore }
        if failed > 0 {
            print("[ChatMessageMapper] ⚠️ 批量解析完成: \(result.count)/\(rows.count) 成功, \(failed) 失败 | context=\(context)")
        }
        return result
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
