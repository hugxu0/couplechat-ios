import Foundation

enum AIMemoryScopeFilter: String, CaseIterable, Identifiable {
    case all
    case shared
    case privateMemory = "private"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .shared: return "两人可见"
        case .privateMemory: return "仅自己"
        }
    }
}

enum AIMemorySubjectFilter: String, CaseIterable, Identifiable {
    case all
    case mine
    case partner
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部人物"
        case .mine: return "我的事情"
        case .partner: return "对方的事情"
        case .both: return "两个人的事情"
        }
    }

    func apiValue(for username: String) -> String? {
        switch self {
        case .all: return nil
        case .mine: return username
        case .partner: return username == "xu" ? "si" : "xu"
        case .both: return "both"
        }
    }
}

enum AIMemoryStatusFilter: String, CaseIterable, Identifiable {
    case active
    case all

    var id: String { rawValue }
    var title: String { self == .active ? "当前记忆" : "含归档" }
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
    let derivedFromCount: Int?
    let version: Int?

    var isShared: Bool { scope == "couple" }
    var visibilityTitle: String { isShared ? "两人可见" : "仅自己可见" }
    var logicalSubject: String {
        if subjects.contains("both") || (subjects.contains("xu") && subjects.contains("si")) {
            return "both"
        }
        return subjects.first ?? "both"
    }
    var subjectTitle: String {
        switch logicalSubject {
        case "xu": return "小旭"
        case "si": return "小偲"
        default: return "两个人"
        }
    }
    var statusTitle: String {
        switch status {
        case "active": return "当前"
        case "superseded": return "已归档"
        case "completed": return "已完成"
        case "cancelled": return "已取消"
        case "expired": return "已过期"
        case "retracted": return "已撤回"
        default: return status
        }
    }

    var eventTimeTitle: String {
        guard let occurredAt else { return "时间未记录" }
        let start = memoryDateTime(occurredAt)
        guard let occurredEndAt, occurredEndAt > occurredAt else { return start }
        return "\(start) 至 \(memoryDateTime(occurredEndAt))"
    }

    private func memoryDateTime(_ milliseconds: Int) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

struct AIMemorySource: Codable, Identifiable, Equatable {
    let id: String
    let layer: AIMemoryLayer
    let content: String
    let subjects: [String]
    let occurredAt: Int?
    let validFrom: Int?
    let updatedAt: Int
}

struct AIMemoryStats: Codable, Equatable {
    let total: Int
    let shared: Int
    let privateCount: Int
    let byLayer: [String: Int]
    let bySubject: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case total, shared, byLayer, bySubject
        case privateCount = "private"
    }

    static let empty = AIMemoryStats(
        total: 0, shared: 0, privateCount: 0, byLayer: [:], bySubject: [:])
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
