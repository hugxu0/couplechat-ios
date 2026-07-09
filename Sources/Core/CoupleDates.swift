import Foundation

struct CoupleDates: Equatable {
    var together: String?
    var lastMeet: String?
    var lastFight: String?

    static func daysSince(_ dateString: String?) -> Int? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let date = f.date(from: dateString) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        return max(0, days)
    }

    static func daysUntil(_ dateString: String?) -> Int? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let date = f.date(from: dateString) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        return max(0, days)
    }
}

struct AnniversaryEntry: Identifiable, Equatable {
    enum Direction: String, Equatable, Hashable {
        case up
        case down
    }

    var id: String
    var title: String
    var date: String
    var direction: Direction
    var icon: String

    var days: Int? {
        switch direction {
        case .up: return CoupleDates.daysSince(date)
        case .down: return CoupleDates.daysUntil(date)
        }
    }

    init(id: String = UUID().uuidString, title: String, date: String, direction: Direction, icon: String) {
        self.id = id
        self.title = title
        self.date = date
        self.direction = direction
        self.icon = icon
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let date = dict["date"] as? String,
              let icon = dict["icon"] as? String else { return nil }
        self.id = id
        self.title = title
        self.date = date
        self.icon = icon
        self.direction = Direction(rawValue: dict["direction"] as? String ?? "") ?? .up
    }

    var asDict: [String: Any] {
        ["id": id, "title": title, "date": date, "direction": direction.rawValue, "icon": icon]
    }
}
