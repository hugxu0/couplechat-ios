import Foundation

struct MomentAlbum: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    var title: String
    var note: String?
    var coverURL: String?
    var coverAssetId: String?
    var itemCount: Int
    var createdAt: Int
    var updatedAt: Int
    var version: Int
    var previewItems: [MomentAsset]

    private enum CodingKeys: String, CodingKey {
        case id, title, note, caption, summary, coverURL, coverUrl, cover, coverAssetId
        case itemCount, assetCount, createdAt, updatedAt, version, previewItems, items
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "未命名相册"
        note = try box.decodeIfPresent(String.self, forKey: .note)
            ?? (try box.decodeIfPresent(String.self, forKey: .caption))
            ?? (try box.decodeIfPresent(String.self, forKey: .summary))
        coverURL = try box.decodeIfPresent(String.self, forKey: .coverURL)
            ?? (try box.decodeIfPresent(String.self, forKey: .coverUrl))
            ?? (try box.decodeIfPresent(String.self, forKey: .cover))
        coverAssetId = try box.decodeIfPresent(String.self, forKey: .coverAssetId)
        itemCount = try box.decodeIfPresent(Int.self, forKey: .itemCount)
            ?? (try box.decodeIfPresent(Int.self, forKey: .assetCount)) ?? 0
        createdAt = box.decodeMilliseconds(for: .createdAt)
        updatedAt = box.decodeMilliseconds(for: .updatedAt)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 0
        previewItems = try box.decodeIfPresent([MomentAsset].self, forKey: .previewItems)
            ?? (try box.decodeIfPresent([MomentAsset].self, forKey: .items)) ?? []
    }

    init(
        id: String,
        title: String,
        note: String? = nil,
        coverURL: String? = nil,
        coverAssetId: String? = nil,
        itemCount: Int = 0,
        createdAt: Int = 0,
        updatedAt: Int = 0,
        version: Int = 0,
        previewItems: [MomentAsset] = []
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.coverURL = coverURL
        self.coverAssetId = coverAssetId
        self.itemCount = itemCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.previewItems = previewItems
    }

    var resolvedCoverURL: URL? {
        ServerConfig.resolveMediaURL(coverURL ?? previewItems.first?.thumbnailURL ?? previewItems.first?.url)
    }
}

struct MomentAsset: Identifiable, Decodable, Equatable, Hashable {
    let id: String
    let albumItemId: String?
    let postId: String?
    let messageId: String?
    let attachmentId: String?
    let mediaType: String
    let url: String
    let thumbnailURL: String?
    var caption: String?
    var noteVersion: Int?
    let addedBy: String?
    let takenAt: Int
    let version: Int

    private enum CodingKeys: String, CodingKey {
        case id, asset, postId, addedAt, messageId, sourceMessageId, attachmentId, mediaType, type, kind, url
        case thumbnailURL, thumbnailUrl, thumbnail, caption, note, addedBy, takenAt, createdAt, version
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try box.decodeIfPresent(MomentAsset.self, forKey: .asset) {
            albumItemId = try box.decodeIfPresent(String.self, forKey: .id)
            postId = try box.decodeIfPresent(String.self, forKey: .postId) ?? nested.postId
            id = nested.id
            messageId = nested.messageId
            attachmentId = nested.attachmentId
            mediaType = nested.mediaType
            url = nested.url
            thumbnailURL = nested.thumbnailURL
            caption = nested.caption
            noteVersion = nested.noteVersion
            addedBy = nested.addedBy
            takenAt = nested.takenAt
            version = nested.version
            return
        }
        id = try box.decode(String.self, forKey: .id)
        albumItemId = nil
        postId = try box.decodeIfPresent(String.self, forKey: .postId)
        messageId = try box.decodeIfPresent(String.self, forKey: .messageId)
            ?? (try box.decodeIfPresent(String.self, forKey: .sourceMessageId))
        attachmentId = try box.decodeIfPresent(String.self, forKey: .attachmentId)
        mediaType = try box.decodeIfPresent(String.self, forKey: .mediaType)
            ?? (try box.decodeIfPresent(String.self, forKey: .type))
            ?? (try box.decodeIfPresent(String.self, forKey: .kind)) ?? "image"
        url = try box.decode(String.self, forKey: .url)
        thumbnailURL = try box.decodeIfPresent(String.self, forKey: .thumbnailURL)
            ?? (try box.decodeIfPresent(String.self, forKey: .thumbnailUrl))
            ?? (try box.decodeIfPresent(String.self, forKey: .thumbnail))
        let structuredNote = try? box.decode(MomentNote.self, forKey: .note)
        let legacyNote = try? box.decode(String.self, forKey: .note)
        caption = try box.decodeIfPresent(String.self, forKey: .caption)
            ?? structuredNote?.text ?? legacyNote
        noteVersion = structuredNote?.version
        addedBy = try box.decodeIfPresent(String.self, forKey: .addedBy)
        takenAt = box.decodeMilliseconds(for: .takenAt, fallback: .createdAt)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    init(
        id: String,
        albumItemId: String? = nil,
        postId: String? = nil,
        messageId: String? = nil,
        attachmentId: String? = nil,
        mediaType: String = "image",
        url: String,
        thumbnailURL: String? = nil,
        caption: String? = nil,
        noteVersion: Int? = nil,
        addedBy: String? = nil,
        takenAt: Int = 0,
        version: Int = 0
    ) {
        self.id = id
        self.albumItemId = albumItemId
        self.postId = postId
        self.messageId = messageId
        self.attachmentId = attachmentId
        self.mediaType = mediaType
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.caption = caption
        self.noteVersion = noteVersion
        self.addedBy = addedBy
        self.takenAt = takenAt
        self.version = version
    }

    var resolvedURL: URL? { ServerConfig.resolveMediaURL(thumbnailURL ?? url) }
    var resolvedOriginalURL: URL? { ServerConfig.resolveMediaURL(url) }
    var isVideo: Bool { mediaType == "video" }

    var mediaBrowserItem: MediaBrowserItem {
        MediaBrowserItem(
            id: id,
            type: isVideo ? "video" : "image",
            url: url,
            text: caption ?? "",
            sentAt: Double(takenAt),
            channel: "album")
    }
}

struct OnThisDayMoment: Identifiable, Decodable, Equatable {
    let id: String
    let yearsAgo: Int
    let title: String
    let date: String
    let assets: [MomentAsset]

    private enum CodingKeys: String, CodingKey {
        case id, yearsAgo, title, date, assets, items
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        yearsAgo = try box.decodeIfPresent(Int.self, forKey: .yearsAgo) ?? 1
        title = try box.decodeIfPresent(String.self, forKey: .title) ?? "那年今日"
        date = try box.decodeIfPresent(String.self, forKey: .date) ?? ""
        assets = try box.decodeIfPresent([MomentAsset].self, forKey: .assets)
            ?? (try box.decodeIfPresent([MomentAsset].self, forKey: .items)) ?? []
        id = try box.decodeIfPresent(String.self, forKey: .id)
            ?? "\(date)-\(yearsAgo)-\(assets.first?.id ?? "moment")"
    }

    init(id: String, yearsAgo: Int, title: String, date: String, assets: [MomentAsset]) {
        self.id = id
        self.yearsAgo = yearsAgo
        self.title = title
        self.date = date
        self.assets = assets
    }
}

struct MomentNote: Decodable, Equatable, Hashable {
    let id: String
    let text: String
    let version: Int
}

struct MomentPage<Value> {
    let values: [Value]
    let nextCursor: String?
}

private extension KeyedDecodingContainer {
    func decodeMilliseconds(
        for key: Key,
        fallback: Key? = nil
    ) -> Int {
        let target = contains(key) ? key : fallback
        guard let target else { return 0 }
        if let value = try? decode(Int.self, forKey: target) { return value }
        if let value = try? decode(Double.self, forKey: target) { return Int(value) }
        if let value = try? decode(String.self, forKey: target), let number = Double(value) {
            return Int(number)
        }
        return 0
    }
}
