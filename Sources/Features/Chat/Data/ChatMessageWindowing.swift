import Foundation

enum ChatMessageWindowing {
    static func mergeSearchResults(
        _ first: [ChatMessage],
        _ second: [ChatMessage]
    ) -> [ChatMessage] {
        var seen = Set<String>()
        return (first + second)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.ts > $1.ts }
    }

    static func mergedWindow(
        _ window: [ChatMessage],
        with current: [ChatMessage],
        around targetId: String
    ) -> [ChatMessage] {
        guard !window.isEmpty else { return current }
        // 搜索上下文本身是一段连续窗口。current 通常是“最新 50 条”，如果把
        // 两者直接拼起来再按数量裁剪，就会得到「目标附近 -> 巨大时间缺口 -> 最新」
        // 的伪连续列表，用户滑过二十多条便会无刷新地抵达最新消息。
        // 这里只允许 current 中与上下文时间范围重叠的消息参与合并，用它们覆盖
        // 同 id 的旧状态；范围外的 confirmed 最新消息必须等向下分页逐页加载。
        let lowerTimestamp = window.map(\.ts).min() ?? -Double.greatestFiniteMagnitude
        let upperTimestamp = window.map(\.ts).max() ?? .greatestFiniteMagnitude
        var messagesByID: [String: ChatMessage] = [:]
        for message in window { messagesByID[message.id] = message }
        for message in current
        where message.ts >= lowerTimestamp && message.ts <= upperTimestamp {
            messagesByID[message.id] = message
        }
        let merged = messagesByID.values.sorted {
            $0.ts == $1.ts ? $0.id < $1.id : $0.ts < $1.ts
        }
        guard let targetIndex = merged.firstIndex(where: { $0.id == targetId }) else {
            return Array(merged.suffix(90))
        }
        let lower = max(0, targetIndex - 40)
        let upper = min(merged.count, targetIndex + 61)
        return Array(merged[lower..<upper])
    }

    static func latestWindow(
        _ latest: [ChatMessage],
        preservingOutboundFrom current: [ChatMessage]
    ) -> [ChatMessage] {
        var seen = Set(latest.map(\.id))
        let confirmedClientIds = Set(latest.compactMap(\.clientId))
        let outbound = current.filter { message in
            guard message.pending || message.failed,
                  !confirmedClientIds.contains(message.clientId ?? "") else { return false }
            return seen.insert(message.id).inserted
        }
        return (latest + outbound).sorted { $0.ts < $1.ts }
    }

    static func dayRange(for date: Date) -> (start: Double, end: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }
}
