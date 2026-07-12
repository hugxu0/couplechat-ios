import SwiftUI

// 自定义表情库：贴纸 + 分组 + 收藏，存在本地（UserDefaults JSON）。
// 贴纸本体在服务器（上传后拿到 url），库里只存 url，发送时把 url 带进消息，
// 对方即可看到；图片本身走 ImageCache 缓存。

struct Sticker: Codable, Identifiable, Equatable {
    let id: String
    var url: String
    var groupId: String
    var favorite: Bool
    var addedAt: Double

    var mediaURL: URL? { ServerConfig.resolveMediaURL(url) }
}

struct StickerGroup: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var order: Int
}

@MainActor
final class StickerStore: ObservableObject {
    /// 全 App 共用一份表情库（couple / ai 两个会话页共享，编辑即时同步）
    static let shared = StickerStore()

    @Published private(set) var stickers: [Sticker] = []
    @Published private(set) var groups: [StickerGroup] = []

    static let defaultGroupId = "default"

    private let stickersKey = "sticker_library_v1"
    private let groupsKey = "sticker_groups_v1"

    init() {
        load()
        if groups.isEmpty {
            groups = [StickerGroup(id: Self.defaultGroupId, name: "我的表情", order: 0)]
            saveGroups()
        }
    }

    // MARK: 读取

    func stickers(in groupId: String) -> [Sticker] {
        stickers.filter { $0.groupId == groupId }.sorted { $0.addedAt > $1.addedAt }
    }

    var favorites: [Sticker] {
        stickers.filter { $0.favorite }.sorted { $0.addedAt > $1.addedAt }
    }

    var sortedGroups: [StickerGroup] {
        groups.sorted { $0.order < $1.order }
    }

    // MARK: 编辑

    func add(url: String, groupId: String = StickerStore.defaultGroupId) {
        let sticker = Sticker(id: UUID().uuidString, url: url, groupId: groupId,
                              favorite: false, addedAt: Date().timeIntervalSince1970)
        stickers.insert(sticker, at: 0)
        saveStickers()
    }

    func delete(_ sticker: Sticker) {
        stickers.removeAll { $0.id == sticker.id }
        saveStickers()
    }

    func toggleFavorite(_ sticker: Sticker) {
        guard let i = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        stickers[i].favorite.toggle()
        saveStickers()
    }

    func move(_ sticker: Sticker, to groupId: String) {
        guard let i = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        stickers[i].groupId = groupId
        saveStickers()
    }

    @discardableResult
    func createGroup(name: String) -> StickerGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = StickerGroup(id: UUID().uuidString,
                                 name: String((trimmed.isEmpty ? "新分组" : trimmed).prefix(8)),
                                 order: (groups.map(\.order).max() ?? 0) + 1)
        groups.append(group)
        saveGroups()
        return group
    }

    func renameGroup(_ group: StickerGroup, to name: String) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        groups[i].name = String(trimmed.prefix(8))
        saveGroups()
    }

    func deleteGroup(_ group: StickerGroup) {
        guard group.id != Self.defaultGroupId else { return }
        // 组里的贴纸挪回默认组，不直接删图
        for i in stickers.indices where stickers[i].groupId == group.id {
            stickers[i].groupId = Self.defaultGroupId
        }
        groups.removeAll { $0.id == group.id }
        saveStickers()
        saveGroups()
    }

    // MARK: 持久化

    private func load() {
        if let data = UserDefaults.standard.data(forKey: stickersKey) {
            if let decoded = try? JSONDecoder().decode([Sticker].self, from: data) {
                stickers = decoded
            } else {
                print("[StickerStore] ⚠️ 贴纸数据解码失败，保留空列表")
            }
        }
        if let data = UserDefaults.standard.data(forKey: groupsKey) {
            if let decoded = try? JSONDecoder().decode([StickerGroup].self, from: data) {
                groups = decoded
            } else {
                print("[StickerStore] ⚠️ 分组数据解码失败，保留空列表")
            }
        }
    }

    private func saveStickers() {
        if let data = try? JSONEncoder().encode(stickers) {
            UserDefaults.standard.set(data, forKey: stickersKey)
        } else {
            print("[StickerStore] ⚠️ 贴纸编码失败，数据未持久化")
        }
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: groupsKey)
        } else {
            print("[StickerStore] ⚠️ 分组编码失败，数据未持久化")
        }
    }
}
