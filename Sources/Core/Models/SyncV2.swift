import Foundation

struct SyncV2Page: Decodable {
    let events: [SyncV2Event]
    let nextCursor: Int64
    let hasMore: Bool
}

struct SyncV2Event: Decodable {
    let seq: Int64
    let entityType: String
    let entityId: String
    let operation: String
    let version: Int64
    let payload: SyncV2Payload
}

struct SyncV2Payload: Decodable {
    let id: String?
    let channel: String?
}

extension Notification.Name {
    static let persistentSyncChanged = Notification.Name("persistentSyncChanged")
}

extension Notification {
    func persistentSyncIncludes(_ candidates: Set<String>) -> Bool {
        guard let values = userInfo?["entityTypes"] as? [String] else { return false }
        return !candidates.isDisjoint(with: Set(values))
    }
}
