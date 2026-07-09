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
}
