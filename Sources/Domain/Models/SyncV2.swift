import Foundation

struct SyncV2Page: Decodable {
    static let supportedProtocolVersion = 2

    let protocolVersion: Int
    let events: [SyncV2Event]
    let nextCursor: Int64
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case events
        case nextCursor
        case hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == Self.supportedProtocolVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported Sync V2 protocol version: \(protocolVersion)")
        }
        self.protocolVersion = protocolVersion
        events = try container.decode([SyncV2Event].self, forKey: .events)
        nextCursor = try container.decode(Int64.self, forKey: .nextCursor)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
    }
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
