import SwiftUI

// 自定义表情库：本地缓存负责离线首屏，情侣共享状态负责双方和多设备同步。
// 贴纸本体在服务器（上传后拿到 url），库里只存 url，发送时把 url 带进消息。

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
    private var sharedSync: (([String: Any]) -> Void)?
    private var applyingSharedState = false
    private var hasAppliedSharedLibrary = false

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
        guard !stickers.contains(where: { $0.url == url }) else { return }
        let sticker = Sticker(id: UUID().uuidString, url: url, groupId: groupId,
                              favorite: false, addedAt: Date().timeIntervalSince1970)
        stickers.insert(sticker, at: 0)
        saveAndSync(stickersChanged: true)
    }

    func delete(_ sticker: Sticker) {
        stickers.removeAll { $0.id == sticker.id }
        saveAndSync(stickersChanged: true)
    }

    func toggleFavorite(_ sticker: Sticker) {
        guard let i = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        stickers[i].favorite.toggle()
        saveAndSync(stickersChanged: true)
    }

    func move(_ sticker: Sticker, to groupId: String) {
        guard let i = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        stickers[i].groupId = groupId
        saveAndSync(stickersChanged: true)
    }

    func moveToFront(_ sticker: Sticker) {
        guard let index = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        let newest = stickers
            .filter { $0.groupId == sticker.groupId }
            .map(\.addedAt)
            .max() ?? Date().timeIntervalSince1970
        stickers[index].addedAt = max(Date().timeIntervalSince1970, newest + 0.001)
        saveAndSync(stickersChanged: true)
    }

    @discardableResult
    func createGroup(name: String) -> StickerGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = StickerGroup(id: UUID().uuidString,
                                 name: String((trimmed.isEmpty ? "新分组" : trimmed).prefix(8)),
                                 order: (groups.map(\.order).max() ?? 0) + 1)
        groups.append(group)
        saveAndSync(groupsChanged: true)
        return group
    }

    func deleteGroup(_ group: StickerGroup) {
        guard group.id != Self.defaultGroupId else { return }
        // 组里的贴纸挪回默认组，不直接删图
        for i in stickers.indices where stickers[i].groupId == group.id {
            stickers[i].groupId = Self.defaultGroupId
        }
        groups.removeAll { $0.id == group.id }
        saveAndSync(stickersChanged: true, groupsChanged: true)
    }

    // MARK: 服务端共享同步

    /// ChatStore 注入共享状态写入器。闭包只在已有登录会话时真正发往服务端。
    func configureSharedSync(_ sync: @escaping ([String: Any]) -> Void) {
        sharedSync = sync
    }

    /// 服务端数据是共同事实源，同时把尚未上传过的本机旧收藏合并进去，避免升级丢表情。
    func applySharedLibrary(_ value: [String: Any]) {
        guard let remoteItems = value["items"] as? [[String: Any]] else { return }
        let remoteGroups = (value["groups"] as? [[String: Any]] ?? []).compactMap {
            Self.group(from: $0)
        }
        var merged = remoteItems.compactMap { Self.sticker(from: $0) }
        if !hasAppliedSharedLibrary {
            let remoteURLs = Set(merged.map(\.url))
            merged.append(contentsOf: stickers.filter { !remoteURLs.contains($0.url) })
        }

        var mergedGroups = remoteGroups
        if !hasAppliedSharedLibrary {
            let groupIDs = Set(mergedGroups.map(\.id))
            mergedGroups.append(contentsOf: groups.filter { !groupIDs.contains($0.id) })
        }
        if !mergedGroups.contains(where: { $0.id == Self.defaultGroupId }) {
            mergedGroups.insert(StickerGroup(id: Self.defaultGroupId, name: "我的表情", order: 0), at: 0)
        }

        applyingSharedState = true
        stickers = merged
        groups = mergedGroups
        saveStickers()
        saveGroups()
        applyingSharedState = false
        let shouldPublishMerge = !hasAppliedSharedLibrary
            && (merged.count != remoteItems.count || mergedGroups.count != remoteGroups.count)
        hasAppliedSharedLibrary = true

        // 本机存在服务端没有的旧收藏时，将合并结果补回服务端。
        if shouldPublishMerge {
            sharedSync?(sharedPayload)
        }
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

    private func saveAndSync(stickersChanged: Bool = false, groupsChanged: Bool = false) {
        if stickersChanged { saveStickers() }
        if groupsChanged { saveGroups() }
        if !applyingSharedState { sharedSync?(sharedPayload) }
    }

    private var sharedPayload: [String: Any] {
        [
            "version": 1,
            "items": stickers.map { sticker -> [String: Any] in
                ["id": sticker.id, "url": sticker.url, "groupId": sticker.groupId,
                 "favorite": sticker.favorite, "addedAt": sticker.addedAt]
            },
            "groups": groups.map { group -> [String: Any] in
                ["id": group.id, "name": group.name, "order": group.order]
            },
        ]
    }

    private static func sticker(from value: [String: Any]) -> Sticker? {
        guard let id = value["id"] as? String,
              let url = value["url"] as? String,
              !id.isEmpty, !url.isEmpty else { return nil }
        return Sticker(
            id: id,
            url: url,
            groupId: value["groupId"] as? String ?? Self.defaultGroupId,
            favorite: value["favorite"] as? Bool ?? true,
            addedAt: (value["addedAt"] as? NSNumber)?.doubleValue
                ?? Date().timeIntervalSince1970)
    }

    private static func group(from value: [String: Any]) -> StickerGroup? {
        guard let id = value["id"] as? String,
              let name = value["name"] as? String,
              !id.isEmpty, !name.isEmpty else { return nil }
        return StickerGroup(
            id: id,
            name: name,
            order: (value["order"] as? NSNumber)?.intValue ?? 0)
    }
}
