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
    /// 乐观并发版本号。服务端一直在回传，此前客户端没有解码，导致提醒备忘是
    /// 唯一没有冲突保护的数据——两台设备同时编辑会静默覆盖。
    var version: Int?

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
