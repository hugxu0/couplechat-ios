import Foundation
import SwiftUI

/// 自定义表情只保存服务端媒体地址。`defaultGroupId` 表示未加入自建分组，
/// 但无论是否分组，表情始终存在于固定的总库中。
struct Sticker: Codable, Identifiable, Equatable {
    let id: String
    var url: String
    var groupId: String
    var addedAt: Double
    /// 冲突合并修订时间；缺失时回退 addedAt。
    var updatedAt: Double? = nil

    var mediaURL: URL? { ServerConfig.resolveMediaURL(url) }
    var revision: Double { updatedAt ?? addedAt }
}

struct StickerGroup: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var order: Int
    /// 冲突合并修订时间；缺失时按 0 处理。
    var updatedAt: Double? = nil

    var revision: Double { updatedAt ?? 0 }
}

private struct StickerTombstoneState: Codable, Equatable {
    var items: [String: Double] = [:]
    var groups: [String: Double] = [:]
}

private struct ResolvedStickerLibrary: Equatable {
    var stickers: [Sticker]
    var groups: [StickerGroup]
    var itemTombstones: [String: Double]
    var groupTombstones: [String: Double]
}

@MainActor
final class StickerStore: ObservableObject {
    static let shared = StickerStore()

    /// 固定总库的内部标识，不对应一个可删除或可显示的自建分组。
    static let defaultGroupId = "default"

    @Published private(set) var stickers: [Sticker] = []
    @Published private(set) var groups: [StickerGroup] = []

    var library: [Sticker] {
        stickers.sorted { lhs, rhs in
            if lhs.addedAt == rhs.addedAt { return lhs.id > rhs.id }
            return lhs.addedAt > rhs.addedAt
        }
    }

    var sortedGroups: [StickerGroup] {
        groups.sorted { lhs, rhs in
            if lhs.order == rhs.order { return lhs.id < rhs.id }
            return lhs.order < rhs.order
        }
    }

    private let defaults: UserDefaults
    private let storagePrefix = "sticker_library_v2"
    private let groupsStoragePrefix = "sticker_groups_v2"
    private let tombstonesStoragePrefix = "sticker_tombstones_v3"
    private var activeUsername: String?
    private var sync: (([String: Any]) -> Void)?
    private var applyingSyncedState = false
    private var initialSyncCompleted = false
    private var itemTombstones: [String: Double] = [:]
    private var groupTombstones: [String: Double] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 账号生命周期

    /// 切换到当前登录账号。每个账号拥有独立本地缓存和独立服务端同步键。
    func activate(username: String) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, activeUsername != username else { return }

        activeUsername = username
        initialSyncCompleted = false
        loadAccountLibrary(username: username)
    }

    func deactivate() {
        activeUsername = nil
        initialSyncCompleted = false
        itemTombstones = [:]
        groupTombstones = [:]
        stickers = []
        groups = []
    }

    /// shared state 仍是情侣级容器，因此用用户名派生独立键；同账号的多台设备读取同一键。
    nonisolated static func sharedKey(for username: String) -> String {
        let encoded = Data(username.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "stickers_user_\(encoded)"
    }

    func configureSync(_ sync: @escaping ([String: Any]) -> Void) {
        self.sync = sync
    }

    // MARK: - 读取

    func stickers(in groupId: String) -> [Sticker] {
        if groupId == Self.defaultGroupId { return library }
        return stickers.filter { $0.groupId == groupId }.sorted { $0.addedAt > $1.addedAt }
    }

    // MARK: - 编辑

    func add(url: String, groupId: String = StickerStore.defaultGroupId) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let revision = nextRevision()
        let clearedTombstone = itemTombstones.removeValue(forKey: url) != nil

        if let index = stickers.firstIndex(where: { $0.url == url }) {
            if isValidCustomGroup(groupId), stickers[index].groupId != groupId {
                stickers[index].groupId = groupId
            }
            // 再次添加同一地址是显式 re-add，必须产生新修订以覆盖较旧删除墓碑。
            stickers[index].updatedAt = revision
            saveAndSync(stickersChanged: true, tombstonesChanged: clearedTombstone)
            return
        }

        stickers.insert(
            Sticker(
                id: UUID().uuidString,
                url: url,
                groupId: normalizedGroupId(groupId),
                addedAt: revision,
                updatedAt: revision),
            at: 0)
        saveAndSync(stickersChanged: true, tombstonesChanged: clearedTombstone)
    }

    func delete(_ sticker: Sticker) {
        guard stickers.contains(where: { $0.id == sticker.id }) else { return }
        let revision = nextRevision()
        stickers.removeAll { $0.url == sticker.url }
        itemTombstones[sticker.url] = max(itemTombstones[sticker.url] ?? 0, revision)
        saveAndSync(stickersChanged: true, tombstonesChanged: true)
    }

    /// 加入某个自建分组；传入 defaultGroupId 表示仅保留在总库。
    func move(_ sticker: Sticker, to groupId: String) {
        guard let index = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        let destination = normalizedGroupId(groupId)
        guard stickers[index].groupId != destination else { return }
        let revision = nextRevision()
        stickers[index].groupId = destination
        stickers[index].updatedAt = revision
        saveAndSync(stickersChanged: true)
    }

    func moveToFront(_ sticker: Sticker) {
        guard let index = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        let newest = stickers.map(\.addedAt).max() ?? Date().timeIntervalSince1970
        let revision = max(nextRevision(), newest + 0.001)
        var moved = stickers.remove(at: index)
        moved.addedAt = revision
        moved.updatedAt = revision
        stickers.insert(moved, at: 0)
        saveAndSync(stickersChanged: true)
    }

    @discardableResult
    func createGroup(name: String) -> StickerGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = nextRevision()
        let group = StickerGroup(
            id: UUID().uuidString,
            name: String((trimmed.isEmpty ? "新分组" : trimmed).prefix(8)),
            order: (groups.map(\.order).max() ?? -1) + 1,
            updatedAt: revision)
        groupTombstones.removeValue(forKey: group.id)
        groups.append(group)
        saveAndSync(groupsChanged: true, tombstonesChanged: true)
        return group
    }

    func deleteGroup(_ group: StickerGroup) {
        guard group.id != Self.defaultGroupId,
              groups.contains(where: { $0.id == group.id }) else { return }
        let revision = nextRevision()

        // 删除的只是分类，表情仍完整保留在固定总库。
        for index in stickers.indices where stickers[index].groupId == group.id {
            stickers[index].groupId = Self.defaultGroupId
            stickers[index].updatedAt = revision
        }
        groupTombstones[group.id] = max(groupTombstones[group.id] ?? 0, revision)
        groups.removeAll { $0.id == group.id }
        normalizeGroupOrder(revision: revision)
        saveAndSync(stickersChanged: true, groupsChanged: true, tombstonesChanged: true)
    }

    // MARK: - 服务端同步

    /// 注入完整 bootstrap 后调用。当前版本只读取账号独立的表情库。
    func completeInitialSync(personalLibrary: [String: Any]?) {
        // Socket 可能先于 bootstrap 返回。此时实时数据更新、更新后的本地缓存都比
        // 较早发出的 bootstrap snapshot 新，不能再用旧快照覆盖。
        guard activeUsername != nil, !initialSyncCompleted else { return }
        if let personalLibrary {
            applySyncedLibrary(personalLibrary)
        } else {
            initialSyncCompleted = true
            publishCurrentLibrary()
        }
    }

    /// Socket 收到本账号的共享状态更新时调用。初次同步会与尚未上传的本地数据合并，
    /// 后续更新则以服务端为事实源，从而让同账号多设备及时一致。
    func applySyncedLibrary(_ value: [String: Any]) {
        guard activeUsername != nil,
              let remoteItems = value["items"] as? [[String: Any]] else { return }

        let remoteGroups = (value["groups"] as? [[String: Any]] ?? [])
            .compactMap(Self.group(from:))
        let remoteItemTombstones = Self.tombstones(
            from: value["itemTombstones"], identifierKey: "url")
        let remoteGroupTombstones = Self.tombstones(
            from: value["groupTombstones"], identifierKey: "id")

        let remoteState = Self.resolve(
            stickers: remoteItems.compactMap(Self.sticker(from:)),
            groups: remoteGroups,
            itemTombstones: remoteItemTombstones,
            groupTombstones: remoteGroupTombstones)
        let mergedState = Self.resolve(
            stickers: remoteItems.compactMap(Self.sticker(from:)) + stickers,
            groups: remoteGroups + groups,
            itemTombstones: Self.mergedTombstones(remoteItemTombstones, itemTombstones),
            groupTombstones: Self.mergedTombstones(remoteGroupTombstones, groupTombstones))

        let shouldPublish = mergedState != remoteState
        let localChanged = mergedState.stickers != stickers
            || mergedState.groups != groups
            || mergedState.itemTombstones != itemTombstones
            || mergedState.groupTombstones != groupTombstones

        if localChanged {
            applyingSyncedState = true
            stickers = mergedState.stickers
            groups = mergedState.groups
            itemTombstones = mergedState.itemTombstones
            groupTombstones = mergedState.groupTombstones
            saveStickers()
            saveGroups()
            saveTombstones()
            applyingSyncedState = false
        }
        initialSyncCompleted = true

        // 仅当本机记录/墓碑让合并结果超出远端时回写。
        // 服务端回显相同 v3 payload 时不会再写，避免多设备形成同步风暴。
        if shouldPublish { publishCurrentLibrary() }
    }

    // MARK: - 本地持久化

    private func loadAccountLibrary(username: String) {
        let userStickersKey = storageKey(prefix: storagePrefix, username: username)
        let userGroupsKey = storageKey(prefix: groupsStoragePrefix, username: username)
        let userTombstonesKey = storageKey(prefix: tombstonesStoragePrefix, username: username)
        let hasAccountData = defaults.object(forKey: userStickersKey) != nil
            || defaults.object(forKey: userGroupsKey) != nil
            || defaults.object(forKey: userTombstonesKey) != nil

        if hasAccountData {
            stickers = decode([Sticker].self, key: userStickersKey) ?? []
            groups = Self.normalizedGroups(decode([StickerGroup].self, key: userGroupsKey) ?? [])
            let tombstones = decode(StickerTombstoneState.self, key: userTombstonesKey)
                ?? StickerTombstoneState()
            itemTombstones = tombstones.items
            groupTombstones = tombstones.groups
        } else {
            stickers = []
            groups = []
            itemTombstones = [:]
            groupTombstones = [:]
        }

        let resolved = Self.resolve(
            stickers: stickers,
            groups: groups,
            itemTombstones: itemTombstones,
            groupTombstones: groupTombstones)
        stickers = resolved.stickers
        groups = resolved.groups
        itemTombstones = resolved.itemTombstones
        groupTombstones = resolved.groupTombstones
        saveStickers()
        saveGroups()
        saveTombstones()
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            print("[StickerStore] ⚠️ 表情数据解码失败: \(key)")
            return nil
        }
        return decoded
    }

    private func saveStickers() {
        guard let username = activeUsername,
              let data = try? JSONEncoder().encode(stickers) else { return }
        defaults.set(data, forKey: storageKey(prefix: storagePrefix, username: username))
    }

    private func saveGroups() {
        guard let username = activeUsername,
              let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: storageKey(prefix: groupsStoragePrefix, username: username))
    }

    private func saveTombstones() {
        guard let username = activeUsername,
              let data = try? JSONEncoder().encode(
                StickerTombstoneState(items: itemTombstones, groups: groupTombstones)) else { return }
        defaults.set(data, forKey: storageKey(prefix: tombstonesStoragePrefix, username: username))
    }

    private func storageKey(prefix: String, username: String) -> String {
        "\(prefix).\(Self.sharedKey(for: username))"
    }

    private func saveAndSync(
        stickersChanged: Bool = false,
        groupsChanged: Bool = false,
        tombstonesChanged: Bool = false
    ) {
        if stickersChanged { saveStickers() }
        if groupsChanged { saveGroups() }
        if tombstonesChanged { saveTombstones() }
        guard !applyingSyncedState else { return }
        if initialSyncCompleted {
            publishCurrentLibrary()
        }
    }

    private func publishCurrentLibrary() {
        guard activeUsername != nil else { return }
        sync?(syncPayload)
    }

    private var syncPayload: [String: Any] {
        [
            "version": 3,
            "items": stickers.map { sticker -> [String: Any] in
                [
                    "id": sticker.id,
                    "url": sticker.url,
                    "groupId": sticker.groupId,
                    "addedAt": sticker.addedAt,
                    "updatedAt": sticker.revision,
                ]
            },
            "groups": sortedGroups.map { group -> [String: Any] in
                [
                    "id": group.id,
                    "name": group.name,
                    "order": group.order,
                    "updatedAt": group.revision,
                ]
            },
            "itemTombstones": itemTombstones.keys.sorted().compactMap { url in
                itemTombstones[url].map { ["url": url, "deletedAt": $0] }
            },
            "groupTombstones": groupTombstones.keys.sorted().compactMap { id in
                groupTombstones[id].map { ["id": id, "deletedAt": $0] }
            },
        ]
    }

    // MARK: - 规范化

    private func normalizedGroupId(_ groupId: String) -> String {
        isValidCustomGroup(groupId) ? groupId : Self.defaultGroupId
    }

    private func isValidCustomGroup(_ groupId: String) -> Bool {
        groupId != Self.defaultGroupId && groups.contains { $0.id == groupId }
    }

    private func normalizeGroupOrder(revision: Double) {
        var ordered = sortedGroups
        for index in ordered.indices where ordered[index].order != index {
            ordered[index].order = index
            ordered[index].updatedAt = max(ordered[index].revision, revision)
        }
        groups = ordered
    }

    private func nextRevision() -> Double {
        let recordRevisions = stickers.map(\.revision) + groups.map(\.revision)
        let tombstoneRevisions = Array(itemTombstones.values) + Array(groupTombstones.values)
        let highestKnown = (recordRevisions + tombstoneRevisions).max() ?? 0
        return max(Date().timeIntervalSince1970, highestKnown + 0.000_001)
    }

    private static func resolve(
        stickers: [Sticker],
        groups: [StickerGroup],
        itemTombstones: [String: Double],
        groupTombstones: [String: Double]
    ) -> ResolvedStickerLibrary {
        var resolvedItemTombstones = itemTombstones
        var resolvedGroupTombstones = groupTombstones
        resolvedGroupTombstones.removeValue(forKey: Self.defaultGroupId)

        var groupsByID = Dictionary(
            uniqueKeysWithValues: mergedGroups(groups).map { ($0.id, $0) })
        for (id, tombstoneRevision) in Array(resolvedGroupTombstones) {
            guard let group = groupsByID[id] else { continue }
            if tombstoneRevision >= group.revision {
                groupsByID.removeValue(forKey: id)
            } else {
                // 明确的新建/更新比旧删除新，删除墓碑已被覆盖。
                resolvedGroupTombstones.removeValue(forKey: id)
            }
        }
        let resolvedGroups = normalizedGroups(Array(groupsByID.values))

        var stickersByURL = Dictionary(
            uniqueKeysWithValues: mergedStickers(stickers).map { ($0.url, $0) })
        for (url, tombstoneRevision) in Array(resolvedItemTombstones) {
            guard let sticker = stickersByURL[url] else { continue }
            if tombstoneRevision >= sticker.revision {
                stickersByURL.removeValue(forKey: url)
            } else {
                // re-add/更新比旧删除新，旧墓碑不应继续占用同步载荷。
                resolvedItemTombstones.removeValue(forKey: url)
            }
        }

        let validGroupIDs = Set(resolvedGroups.map(\.id))
        var resolvedStickers = Array(stickersByURL.values)
        for index in resolvedStickers.indices {
            let groupID = resolvedStickers[index].groupId
            guard groupID != Self.defaultGroupId, !validGroupIDs.contains(groupID) else { continue }
            resolvedStickers[index].groupId = Self.defaultGroupId
            resolvedStickers[index].updatedAt = max(
                resolvedStickers[index].revision,
                resolvedGroupTombstones[groupID] ?? 0)
        }
        resolvedStickers.sort { lhs, rhs in
            if lhs.addedAt == rhs.addedAt { return lhs.id > rhs.id }
            return lhs.addedAt > rhs.addedAt
        }

        return ResolvedStickerLibrary(
            stickers: resolvedStickers,
            groups: resolvedGroups,
            itemTombstones: resolvedItemTombstones,
            groupTombstones: resolvedGroupTombstones)
    }

    private static func mergedStickers(_ items: [Sticker]) -> [Sticker] {
        var byURL: [String: Sticker] = [:]
        for rawSticker in items {
            var sticker = rawSticker
            sticker.updatedAt = sticker.revision
            guard let current = byURL[sticker.url] else {
                byURL[sticker.url] = sticker
                continue
            }
            if prefers(sticker, over: current) { byURL[sticker.url] = sticker }
        }
        return Array(byURL.values)
    }

    private static func mergedGroups(_ items: [StickerGroup]) -> [StickerGroup] {
        var byID: [String: StickerGroup] = [:]
        for rawGroup in items where rawGroup.id != Self.defaultGroupId {
            var group = rawGroup
            group.updatedAt = group.revision
            guard let current = byID[group.id] else {
                byID[group.id] = group
                continue
            }
            if prefers(group, over: current) { byID[group.id] = group }
        }
        return Array(byID.values)
    }

    private static func prefers(_ candidate: Sticker, over current: Sticker) -> Bool {
        if candidate.revision != current.revision { return candidate.revision > current.revision }
        if candidate.id != current.id { return candidate.id > current.id }
        if candidate.groupId != current.groupId { return candidate.groupId > current.groupId }
        return candidate.addedAt > current.addedAt
    }

    private static func prefers(_ candidate: StickerGroup, over current: StickerGroup) -> Bool {
        if candidate.revision != current.revision { return candidate.revision > current.revision }
        if candidate.name != current.name { return candidate.name > current.name }
        return candidate.order > current.order
    }

    private static func normalizedGroups(_ items: [StickerGroup]) -> [StickerGroup] {
        var result = mergedGroups(items)
            .sorted { lhs, rhs in
                if lhs.order == rhs.order { return lhs.id < rhs.id }
                return lhs.order < rhs.order
            }
        for index in result.indices { result[index].order = index }
        return result
    }

    private static func mergedTombstones(
        _ lhs: [String: Double],
        _ rhs: [String: Double]
    ) -> [String: Double] {
        var result = lhs
        for (identifier, revision) in rhs {
            result[identifier] = max(result[identifier] ?? 0, revision)
        }
        return result
    }

    private static func tombstones(
        from rawValue: Any?,
        identifierKey: String
    ) -> [String: Double] {
        guard let values = rawValue as? [[String: Any]] else { return [:] }
        var result: [String: Double] = [:]
        for value in values {
            guard let identifier = value[identifierKey] as? String,
                  !identifier.isEmpty,
                  let revision = (value["deletedAt"] as? NSNumber)?.doubleValue else { continue }
            result[identifier] = max(result[identifier] ?? 0, revision)
        }
        return result
    }

    private static func sticker(from value: [String: Any]) -> Sticker? {
        guard let id = value["id"] as? String,
              let url = value["url"] as? String,
              !id.isEmpty, !url.isEmpty else { return nil }
        let addedAt = (value["addedAt"] as? NSNumber)?.doubleValue
            ?? Date().timeIntervalSince1970
        return Sticker(
            id: id,
            url: url,
            groupId: value["groupId"] as? String ?? Self.defaultGroupId,
            addedAt: addedAt,
            updatedAt: (value["updatedAt"] as? NSNumber)?.doubleValue ?? addedAt)
    }

    private static func group(from value: [String: Any]) -> StickerGroup? {
        guard let id = value["id"] as? String,
              let name = value["name"] as? String,
              !id.isEmpty, !name.isEmpty else { return nil }
        return StickerGroup(
            id: id,
            name: name,
            order: (value["order"] as? NSNumber)?.intValue ?? 0,
            updatedAt: (value["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
    }
}
