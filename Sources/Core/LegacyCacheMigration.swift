import Foundation

enum LegacyCacheMigration {
    struct Snapshot: Codable {
        var username: String
        var savedAt: Double
        var messagesByChannel: [String: [ChatMessage]]
        var readStates: [String: [String: Double]]
        var partner: Account?
        var sharedStateData: Data?
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func load(for username: String) -> Snapshot? {
        let url = cacheURL(for: username)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.username == username else { return nil }
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        let url = cacheURL(for: snapshot.username)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache failures should never affect chat usage.
        }
    }

    static func clear(for username: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: username))
    }

    static func encodeSharedState(_ state: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(state) else { return nil }
        return try? JSONSerialization.data(withJSONObject: state)
    }

    static func decodeSharedState(_ data: Data?) -> [String: Any] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let state = object as? [String: Any] else { return [:] }
        return state
    }

    private static func cacheURL(for username: String) -> URL {
        let safeUsername = username
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatCache", isDirectory: true)
            .appendingPathComponent("\(safeUsername).json")
    }
}
