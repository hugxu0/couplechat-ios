import Foundation

enum RecommendationSourceKind: String, Codable {
    case daju
    case member
}

struct RecommendationItem: Codable, Identifiable, Equatable {
    let id: String
    let sourceKind: RecommendationSourceKind
    let sourceUsername: String?
    let sourceName: String
    let recipientUsername: String?
    let category: String?
    let content: String
    let cycleDate: String
    let generationKind: String
    let createdAt: Int
    var isRead: Bool
    let isMine: Bool

    var isFromDaju: Bool { sourceKind == .daju }
}

struct RecommendationTodaySnapshot: Decodable, Equatable {
    let cycleDate: String
    var daju: RecommendationItem
    var partner: RecommendationItem?
    var latestUnread: RecommendationItem?
    var unreadCount: Int
}

struct RecommendationHistoryPage: Decodable, Equatable {
    let recommendations: [RecommendationItem]
    let nextCursor: String?
    let hasMore: Bool
}
