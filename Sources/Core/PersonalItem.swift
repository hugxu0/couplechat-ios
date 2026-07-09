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
}
