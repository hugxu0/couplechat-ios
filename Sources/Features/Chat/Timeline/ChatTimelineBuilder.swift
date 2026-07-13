import Foundation

struct ChatTimelineBuildResult {
    let items: [ChatTimelineItem]
    let messagesById: [String: ChatMessage]
    let groupedMessageIds: Set<String>
    let reeditMessageIdsByItemId: [String: String]
}

enum ChatTimelineBuilder {
    static func build(
        messages: [ChatMessage],
        activity: ChatMessage? = nil,
        currentUsername: String? = nil,
        canReeditRecall: (String) -> Bool = { _ in false },
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = Date()
    ) -> ChatTimelineBuildResult {
        var messagesById: [String: ChatMessage] = [:]
        for message in messages { messagesById[message.id] = message }
        var items: [ChatTimelineItem] = []
        var grouped = Set<String>()
        var reeditMessageIds: [String: String] = [:]

        for (index, message) in messages.enumerated() {
            let separatesTime = index == 0
                || !calendar.isDate(message.date, inSameDayAs: messages[index - 1].date)
                || message.ts - messages[index - 1].ts > 8 * 60 * 1_000
            if separatesTime {
                items.append(.time(
                    id: "time-\(message.id)",
                    text: timeLabel(for: message.date, calendar: calendar, now: now)))
            } else if messages[index - 1].sender == message.sender,
                      messages[index - 1].kind != "system" {
                grouped.insert(message.id)
            }
            if message.kind == "system" {
                let itemId = "system-\(message.id)"
                if let recall = message.meta?.recallNotice {
                    let mine = recall.by == currentUsername
                    let text = mine ? "你撤回了一条消息" : "\(recall.byName)撤回了一条消息"
                    items.append(.system(id: itemId, text: text))
                    if mine, canReeditRecall(recall.messageId) {
                        reeditMessageIds[itemId] = recall.messageId
                    }
                } else {
                    items.append(.system(id: itemId, text: message.text))
                }
            } else {
                items.append(.message(id: message.id))
            }
        }

        if let activity {
            messagesById[activity.id] = activity
            items.append(.message(id: activity.id))
        }
        return ChatTimelineBuildResult(
            items: items,
            messagesById: messagesById,
            groupedMessageIds: grouped,
            reeditMessageIdsByItemId: reeditMessageIds)
    }

    static func timeLabel(for date: Date, calendar: Calendar, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = "昨天 HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }
}
