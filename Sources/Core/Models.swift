import Foundation

// 数据模型：字段与服务端 src/store/messages.js 的 createMessage 一一对应。

struct Account: Codable, Equatable {
    let username: String
    let name: String
}

struct Session: Codable {
    let token: String
    let username: String
    let name: String
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
        ts = (dict["ts"] as? NSNumber)?.doubleValue ?? 0
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

    var date: Date { Date(timeIntervalSince1970: ts / 1000) }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
