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
    let pairedVideoURL: String?

    init?(message: ChatMessage) {
        guard let url = message.url, !url.isEmpty else { return nil }
        id = message.id
        type = message.type
        self.url = url
        text = message.text
        senderName = message.senderName
        sentAt = message.ts
        channel = message.channel
        pairedVideoURL = nil
    }

    init(message: ChatMessage, attachment: ChatAttachment, pairedVideo: ChatAttachment?) {
        id = attachment.id
        type = "image"
        url = attachment.url
        text = message.text
        senderName = message.senderName
        sentAt = message.ts
        channel = message.channel
        pairedVideoURL = pairedVideo?.url
    }

    static func items(for message: ChatMessage) -> [MediaBrowserItem] {
        let attachments = message.attachments ?? []
        let photos = attachments.filter { $0.role == "photo" }.sorted { $0.order < $1.order }
        guard !photos.isEmpty else { return MediaBrowserItem(message: message).map { [$0] } ?? [] }
        return photos.map { photo in
            MediaBrowserItem(
                message: message,
                attachment: photo,
                pairedVideo: attachments.first { $0.assetId == photo.assetId && $0.role == "pairedVideo" })
        }
    }

    var mediaURL: URL? { ServerConfig.resolveMediaURL(url) }
    var isVideo: Bool { type == "video" }
    var isLivePhoto: Bool { pairedVideoURL != nil }
    var pairedVideoMediaURL: URL? { ServerConfig.resolveMediaURL(pairedVideoURL) }
}

@MainActor
final class MediaFavoriteStore: ObservableObject {
    static let shared = MediaFavoriteStore()

    @Published private(set) var items: [MediaBrowserItem] = []
    private let storageKey = "media_favorites_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([MediaBrowserItem].self, from: data) {
            items = saved
        }
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

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
