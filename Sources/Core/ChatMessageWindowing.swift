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
        var seen = Set<String>()
        let merged = (window + current)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.ts < $1.ts }
        guard let targetIndex = merged.firstIndex(where: { $0.id == targetId }) else {
            return Array(merged.suffix(90))
        }
        let lower = max(0, targetIndex - 36)
        let upper = min(merged.count, targetIndex + 42)
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
