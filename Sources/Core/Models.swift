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

    /// 倒数纪念日：目标日期减今天，已过去的日子记 0
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

/// 自由添加的纪念日 / 倒数日（存在 shared["anniversaries"]，两人共享可编辑）
struct AnniversaryEntry: Identifiable, Equatable {
    enum Direction: String, Equatable, Hashable {
        case up    // 距今已经过去多少天
        case down  // 距离未来还有多少天
    }

    var id: String
    var title: String
    var date: String       // "yyyy-MM-dd"
    var direction: Direction
    var icon: String       // SF Symbol 名称

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

enum AccountPresentation {
    static func avatar(for username: String) -> String {
        switch username {
        case "xu": return "🐶"
        case "si": return "🐰"
        default: return "💗"
        }
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
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
    var replyTo: String?      // 引用的消息 ID
    var replyPreview: String? // 引用预览文本（发送者 + 内容摘要）

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
        recalledText = dict["recalledText"] as? String
        if let reply = dict["reply"] as? [String: Any] {
            replyTo = reply["id"] as? String ?? reply["replyTo"] as? String
            replyPreview = reply["preview"] as? String ?? reply["replyPreview"] as? String
        } else {
            replyTo = dict["replyTo"] as? String
            replyPreview = dict["replyPreview"] as? String
        }
    }

    /// 乐观占位消息：发送瞬间先上屏，服务端确认后对号入座
    init(optimisticText text: String, me: Session, clientId: String, channel: String,
         replyTo: String? = nil, replyPreview: String? = nil) {
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
        self.replyTo = replyTo
        self.replyPreview = replyPreview
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
