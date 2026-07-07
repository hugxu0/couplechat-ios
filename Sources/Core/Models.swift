import Foundation

// 数据模型：字段与新后端 server/docs/API.md 的契约对齐。

struct Account: Codable, Equatable {
    let username: String
    let name: String
    let avatar: String?
}

struct Session: Codable {
    let token: String
    let username: String
    let name: String
}

enum ChatChannel: String, CaseIterable, Identifiable {
    case couple
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .couple: return "聊天"
        case .ai: return "大橘"
        }
    }
}

// MARK: - 统计 / 每日内容（对应 GET /api/stats、GET /api/daily）

struct DayStat: Decodable, Equatable {
    let date: String        // "2026-07-07"
    let weekday: String     // "一" ... "今"
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }
}

struct MonthStat: Decodable, Equatable {
    let month: String       // "2026-07"
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }
}

struct StatsResponse: Decodable, Equatable {
    let days: [DayStat]
    let months: [MonthStat]
}

struct DiaryEntry: Decodable, Equatable {
    let date: String
    let text: String
}

struct Recommendation: Decodable, Equatable {
    let category: String
    let title: String
    let reason: String
}

struct DailyContent: Decodable, Equatable {
    let diary: DiaryEntry?
    let recommend: Recommendation?
}

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

/// 纪念日（存在 shared["dates"]，两人共享可编辑）
struct CoupleDates: Equatable {
    var together: String?   // 在一起的日子 "yyyy-MM-dd"
    var lastMeet: String?   // 上次见面
    var lastFight: String?  // 上次吵架

    static func daysSince(_ dateString: String?) -> Int? {
        guard let dateString, !dateString.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let date = f.date(from: dateString) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        return max(0, days)
    }
}

enum AccountPresentation {
    static func avatar(for username: String) -> String {
        switch username {
        case "xu": return "🐶"
        case "si": return "🐰"
        default: return "💗"
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var sender: String
    var senderName: String
    var kind: String        // user / system
    var type: String        // text / image / video / sticker / voice
    var text: String
    var url: String?
    var channel: String     // couple / ai
    var ts: Double          // 毫秒时间戳
    var clientId: String?
    var recalledText: String? // 撤回前原文保留，用于重新编辑

    // 本地状态（乐观发送用，不来自服务端）
    var pending = false
    var failed = false

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return nil }
        self.id = id
        sender = dict["sender"] as? String ?? ""
        senderName = dict["senderName"] as? String ?? ""
        kind = dict["kind"] as? String ?? "user"
        type = dict["type"] as? String ?? "text"
        text = dict["text"] as? String ?? ""
        url = dict["url"] as? String
        channel = dict["channel"] as? String ?? "couple"
        if let value = dict["ts"] as? NSNumber {
            ts = value.doubleValue
        } else if let value = dict["ts"] as? Double {
            ts = value
        } else if let value = dict["ts"] as? Int {
            ts = Double(value)
        } else {
            ts = 0
        }
        clientId = dict["clientId"] as? String
    }

    /// 乐观占位消息：发送瞬间先上屏，服务端确认后对号入座
    init(optimisticText text: String, me: Session, clientId: String, channel: String) {
        self.id = clientId
        self.clientId = clientId
        self.sender = me.username
        self.senderName = me.name
        self.kind = "user"
        self.type = "text"
        self.text = text
        self.url = nil
        self.channel = channel
        self.ts = Date().timeIntervalSince1970 * 1000
        self.pending = true
    }

    init(optimisticMedia type: String, text: String, localURL: String?, me: Session, clientId: String, channel: String) {
        self.id = clientId
        self.clientId = clientId
        self.sender = me.username
        self.senderName = me.name
        self.kind = "user"
        self.type = type
        self.text = text
        self.url = localURL
        self.channel = channel
        self.ts = Date().timeIntervalSince1970 * 1000
        self.pending = true
    }

    var date: Date { Date(timeIntervalSince1970: ts / 1000) }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
