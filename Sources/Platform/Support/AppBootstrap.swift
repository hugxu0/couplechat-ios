import Foundation

struct AppBootstrapSnapshot {
    let accounts: [Account]
    let messagesByChannel: [String: [ChatMessage]]
    let readStates: [String: [String: Double]]
    let sharedState: [String: Any]

    @MainActor
    static func decode(_ data: Data) throws -> AppBootstrapSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true else {
            throw BootstrapError.invalidResponse
        }

        let accountRows = root["accounts"] as? [[String: Any]] ?? []
        let accounts = accountRows.compactMap { row -> Account? in
            guard let username = row["username"] as? String,
                  let name = row["name"] as? String else { return nil }
            return Account(username: username, name: name, avatar: row["avatar"] as? String)
        }

        let messageRoot = root["messages"] as? [String: Any] ?? [:]
        var messagesByChannel: [String: [ChatMessage]] = [:]
        for channel in ChatChannel.allCases {
            let rows = messageRoot[channel.rawValue] as? [[String: Any]] ?? []
            let parsed = ChatMessageMapper.parse(rows, context: "bootstrap:\(channel.rawValue)")
            messagesByChannel[channel.rawValue] = parsed.filter { $0.channel == channel.rawValue }
        }

        let readRoot = root["readStates"] as? [String: Any] ?? [:]
        var readStates: [String: [String: Double]] = [:]
        for channel in ChatChannel.allCases {
            let raw = readRoot[channel.rawValue] as? [String: Any] ?? [:]
            readStates[channel.rawValue] = raw.compactMapValues {
                ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double)
            }
        }

        return AppBootstrapSnapshot(
            accounts: accounts,
            messagesByChannel: messagesByChannel,
            readStates: readStates,
            sharedState: root["sharedState"] as? [String: Any] ?? [:])
    }
}

enum BootstrapError: LocalizedError {
    case invalidResponse
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器初始化数据格式不正确"
        case .unauthorized: return "登录已过期，请重新登录"
        case let .server(message): return message
        }
    }
}
