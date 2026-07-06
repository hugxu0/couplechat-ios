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
