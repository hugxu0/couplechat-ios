import Foundation

enum PersonalItemKind: String, Codable, Equatable {
    case reminder
    case memo
}

struct PersonalItem: Identifiable, Codable, Equatable {
    let id: String
    let owner: String
    var kind: PersonalItemKind
    var scope: String
    var title: String
    var bodyMarkdown: String
    var dueAt: Int?
    var isDone: Bool
    let createdAt: Int
    var updatedAt: Int

    var dueDate: Date? {
        guard let dueAt else { return nil }
        return Date(timeIntervalSince1970: Double(dueAt) / 1000)
    }

    var isOverdue: Bool {
        guard let dueDate else { return false }
        return !isDone && dueDate < Date()
    }

    var isToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }
}

extension Date {
    /// 提醒到期时间展示：今天/明天优先，其余用月日。
    var smartLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(self) {
            formatter.dateFormat = "今天 HH:mm"
        } else if Calendar.current.isDateInTomorrow(self) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: self)
    }
}
