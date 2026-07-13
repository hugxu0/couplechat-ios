import Foundation

enum AIMemoryScopeFilter: String, CaseIterable, Identifiable {
    case all
    case shared
    case privateMemory = "private"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .shared: return "共同"
        case .privateMemory: return "我的"
        }
    }
}

enum AIMemoryLayer: String, Codable, CaseIterable, Identifiable {
    case fact
    case event
    case plan
    case state
    case relationship
    case insight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fact: return "事实"
        case .event: return "经历"
        case .plan: return "计划"
        case .state: return "近况"
        case .relationship: return "关系"
        case .insight: return "理解"
        }
    }
}

struct AIMemoryItem: Codable, Identifiable, Equatable {
    let id: String
    let layer: AIMemoryLayer
    let scope: String
    let memoryKey: String
    let subjects: [String]
    let speakers: [String]
    var content: String
    let category: String
    let confidence: Double
    var importance: Int
    let occurredAt: Int?
    let occurredEndAt: Int?
    let validFrom: Int?
    let validUntil: Int?
    let status: String
    let supersedesId: String?
    let createdAt: Int
    var updatedAt: Int
    let evidenceCount: Int
    let version: Int?

    var isShared: Bool { scope == "couple" }
}

struct AIMemoryEvidence: Codable, Identifiable, Equatable {
    let messageId: String
    let channel: String
    let sender: String
    let messageTs: Int
    let excerpt: String
    let role: String

    var id: String { messageId }
}

struct AIMemoryStats: Codable, Equatable {
    let total: Int
    let shared: Int
    let privateCount: Int
    let byLayer: [String: Int]

    enum CodingKeys: String, CodingKey {
        case total, shared, byLayer
        case privateCount = "private"
    }

    static let empty = AIMemoryStats(total: 0, shared: 0, privateCount: 0, byLayer: [:])
}

struct AIMemorySnapshot: Equatable {
    let items: [AIMemoryItem]
    let stats: AIMemoryStats
    let nextCursor: String?
    let hasMore: Bool

    init(
        items: [AIMemoryItem],
        stats: AIMemoryStats,
        nextCursor: String? = nil,
        hasMore: Bool = false
    ) {
        self.items = items
        self.stats = stats
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
