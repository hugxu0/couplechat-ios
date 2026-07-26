import Foundation

@MainActor
final class CardGameViewModel: ObservableObject {
    @Published private(set) var snapshot: CardGameSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published var errorMessage: String?

    private let repository: CardGameRepository
    private var account: String?
    private var activeLoadID: UUID?
    private var generation = 0
    // 幂等键按"用户意图"生成：失败重试沿用同一个键，服务端才能识别重复请求。
    // 每次调用都换新键会让超时重试变成第二次扣次数/扣卡。
    private var drawIntentKey: String?
    private var useIntent: (signature: String, key: String)?
    /// 翻牌演出期间新快照先压着，收尾时才提交——否则卡库/计数在动画中途
    /// 重排，底部页面会抖动。
    private var pendingSnapshot: CardGameSnapshot?

    init(repository: CardGameRepository = CardGameRepository()) {
        self.repository = repository
    }

    func commitPendingSnapshot() {
        if let pendingSnapshot {
            snapshot = pendingSnapshot
            self.pendingSnapshot = nil
        }
    }

    func load(token: String, username: String, force: Bool = false) async {
        prepareAccount(username)
        guard pendingSnapshot == nil else { return }
        guard force || snapshot == nil else { return }
        guard activeLoadID == nil, !isMutating else { return }
        let loadID = UUID()
        activeLoadID = loadID
        let currentGeneration = generation
        isLoading = snapshot == nil
        defer {
            if activeLoadID == loadID {
                activeLoadID = nil
                isLoading = false
            }
        }
        do {
            let fresh = try await repository.fetch(token: token)
            guard currentGeneration == generation, account == username else { return }
            snapshot = fresh
            errorMessage = nil
        } catch {
            guard currentGeneration == generation, account == username else { return }
            errorMessage = error.localizedDescription
        }
    }

    func draw(token: String, username: String) async -> CardGameDraw? {
        guard !isMutating else { return nil }
        isMutating = true
        defer { isMutating = false }
        let key = drawIntentKey ?? UUID().uuidString
        drawIntentKey = key
        do {
            let result = try await repository.draw(token: token, idempotencyKey: key)
            guard account == username else { return nil }
            drawIntentKey = nil
            pendingSnapshot = result.snapshot
            errorMessage = nil
            return result.draw
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func use(
        token: String,
        username: String,
        item: CardGameInventoryItem,
        effectID: String? = nil,
        source: CardGameInventoryItem? = nil
    ) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        defer { isMutating = false }
        let signature = [item.cardKey, item.rarity.rawValue, effectID ?? "-",
                         source?.cardKey ?? "-", source?.rarity.rawValue ?? "-"].joined(separator: "|")
        let key = useIntent?.signature == signature ? useIntent!.key : UUID().uuidString
        useIntent = (signature, key)
        do {
            let result = try await repository.use(
                token: token,
                cardKey: item.cardKey,
                rarity: item.rarity,
                effectID: effectID,
                sourceCardKey: source?.cardKey,
                sourceRarity: source?.rarity,
                idempotencyKey: key)
            guard account == username else { return false }
            useIntent = nil
            snapshot = result.snapshot
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func prepareAccount(_ username: String) {
        guard account != username else { return }
        account = username
        generation += 1
        activeLoadID = nil
        snapshot = nil
        errorMessage = nil
        isLoading = false
        isMutating = false
        drawIntentKey = nil
        useIntent = nil
        pendingSnapshot = nil
    }
}
