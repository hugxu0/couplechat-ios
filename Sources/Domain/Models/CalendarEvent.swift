import Foundation

struct CalendarEvent: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let owner: String
    var scope: String
    var title: String
    var notes: String
    var startAt: Int
    var endAt: Int?
    var timezone: String
    var isAllDay: Bool
    var isDone: Bool
    let createdAt: Int
    var updatedAt: Int
    var version: Int
    var participants: [CalendarParticipant]

    private enum CodingKeys: String, CodingKey {
        case id, owner, ownerUsername, scope, title, notes, bodyMarkdown
        case startAt, startsAt, endAt, endsAt, timezone, isAllDay, allDay, isDone, status
        case createdAt, updatedAt, version, participants
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        owner = try box.decodeIfPresent(String.self, forKey: .owner)
            ?? (try box.decodeIfPresent(String.self, forKey: .ownerUsername)) ?? ""
        let serverScope = try box.decodeIfPresent(String.self, forKey: .scope) ?? "shared"
        scope = serverScope == "private" ? "personal" : serverScope
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "未命名日程"
        notes = try box.decodeIfPresent(String.self, forKey: .notes)
            ?? (try box.decodeIfPresent(String.self, forKey: .bodyMarkdown)) ?? ""
        startAt = box.flexibleInt(.startAt) ?? box.flexibleInt(.startsAt) ?? 0
        endAt = box.flexibleInt(.endAt) ?? box.flexibleInt(.endsAt)
        timezone = try box.decodeIfPresent(String.self, forKey: .timezone) ?? TimeZone.current.identifier
        isAllDay = try box.decodeIfPresent(Bool.self, forKey: .isAllDay)
            ?? (try box.decodeIfPresent(Bool.self, forKey: .allDay)) ?? false
        if let done = try box.decodeIfPresent(Bool.self, forKey: .isDone) {
            isDone = done
        } else {
            isDone = (try box.decodeIfPresent(String.self, forKey: .status)) == "completed"
        }
        createdAt = box.flexibleInt(.createdAt) ?? 0
        updatedAt = box.flexibleInt(.updatedAt) ?? 0
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 0
        participants = try box.decodeIfPresent([CalendarParticipant].self, forKey: .participants) ?? []
    }

    init(
        id: String,
        owner: String,
        scope: String,
        title: String,
        notes: String = "",
        startAt: Int,
        endAt: Int? = nil,
        timezone: String = TimeZone.current.identifier,
        isAllDay: Bool = false,
        isDone: Bool = false,
        createdAt: Int = 0,
        updatedAt: Int = 0,
        version: Int = 0,
        participants: [CalendarParticipant] = []
    ) {
        self.id = id
        self.owner = owner
        self.scope = scope
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.timezone = timezone
        self.isAllDay = isAllDay
        self.isDone = isDone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.participants = participants
    }

    var startDate: Date { Date(timeIntervalSince1970: Double(startAt) / 1_000) }
    var endDate: Date? { endAt.map { Date(timeIntervalSince1970: Double($0) / 1_000) } }
}

struct CalendarParticipant: Decodable, Equatable, Hashable {
    let accountId: String
    let username: String
    let displayName: String
    let status: String
}

private extension KeyedDecodingContainer {
    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key), let number = Double(value) {
            return Int(number)
        }
        return nil
    }
}
