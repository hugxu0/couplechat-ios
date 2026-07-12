import SwiftUI

/// 可在聊天预览与「我的 → 收藏」之间复用的媒体描述。
/// 只持久化服务端媒体地址与展示信息，不复制图片文件，避免收藏无限占用本地空间。
struct MediaBrowserItem: Identifiable, Codable, Equatable {
    let id: String
    let type: String
    let url: String
    let text: String
    let senderName: String
    let sentAt: Double
    let channel: String

    init?(message: ChatMessage) {
        guard let url = message.url, !url.isEmpty else { return nil }
        id = message.id
        type = message.type
        self.url = url
        text = message.text
        senderName = message.senderName
        sentAt = message.ts
        channel = message.channel
    }

    static func items(for message: ChatMessage) -> [MediaBrowserItem] {
        MediaBrowserItem(message: message).map { [$0] } ?? []
    }

    var mediaURL: URL? { ServerConfig.resolveMediaURL(url) }
    var isVideo: Bool { type == "video" }
}

@MainActor
final class MediaFavoriteStore: ObservableObject {
    static let shared = MediaFavoriteStore()

    @Published private(set) var items: [MediaBrowserItem] = []
    private let storagePrefix = "media_favorites_v2"
    private let legacyStorageKey = "media_favorites_v1"
    private var activeUsername: String?

    private init() {}

    func activate(username: String) {
        guard activeUsername != username else { return }
        activeUsername = username
        let key = storageKey(for: username)
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([MediaBrowserItem].self, from: data) {
            items = saved
            return
        }
        // 旧版本未分账号。只迁移明确属于双方公共频道的收藏；AI/未知频道可能
        // 暴露另一账号的私有内容，因此升级时直接丢弃。
        if let legacy = UserDefaults.standard.data(forKey: legacyStorageKey) {
            let decoded = (try? JSONDecoder().decode([MediaBrowserItem].self, from: legacy)) ?? []
            items = Self.legacyItemsEligibleForMigration(decoded)
            save()
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
        } else {
            items = []
        }
    }

    func deactivate() {
        activeUsername = nil
        items = []
    }

    func contains(_ item: MediaBrowserItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    @discardableResult
    func toggle(_ item: MediaBrowserItem) -> Bool {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
            save()
            return false
        }
        items.insert(item, at: 0)
        save()
        return true
    }

    func remove(_ item: MediaBrowserItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func remove(messageId: String) {
        let originalCount = items.count
        items.removeAll { $0.id == messageId }
        if items.count != originalCount { save() }
    }

    private func save() {
        guard let username = activeUsername,
              let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey(for: username))
    }

    private func storageKey(for username: String) -> String {
        "\(storagePrefix).\(username)"
    }

    nonisolated static func legacyItemsEligibleForMigration(
        _ items: [MediaBrowserItem]
    ) -> [MediaBrowserItem] {
        items.filter { $0.channel == ChatChannel.couple.rawValue }
    }
}
