import Foundation

struct ChatHeaderModel: Equatable {
    enum Connection: String, Equatable {
        case online
        case offline
        case connecting
        case failed
        case aiComposing
    }

    let title: String
    let subtitle: String
    let avatar: String
    let connection: Connection
    let isAIComposing: Bool
}
