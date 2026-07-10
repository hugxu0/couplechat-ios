import Foundation

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

enum AccountPresentation {
    static func avatar(for username: String) -> String {
        switch username {
        case "xu": return "🐶"
        case "si": return "🐰"
        default: return "💗"
        }
    }

    /// 旧数据中 avatar 既可能是 emoji，也可能是 /uploads/... 地址。
    /// 文字占位只接受短文本，媒体路径必须交给图片加载器。
    static func avatarText(_ raw: String?, for username: String) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !isMediaReference(raw) else {
            return avatar(for: username)
        }
        return raw.count <= 4 ? raw : avatar(for: username)
    }

    static func mediaURL(_ raw: String?) -> URL? {
        guard let raw, isMediaReference(raw) else { return nil }
        return ServerConfig.resolveMediaURL(raw)
    }

    private static func isMediaReference(_ raw: String) -> Bool {
        raw.hasPrefix("/") || raw.hasPrefix("uploads/") || raw.hasPrefix("http://")
            || raw.hasPrefix("https://") || raw.hasPrefix("file://")
    }
}
