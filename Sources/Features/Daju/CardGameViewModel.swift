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

    init(repository: CardGameRepository = CardGameRepository()) {
        self.repository = repository
    }

    func load(token: String, username: String, force: Bool = false) async {
        prepareAccount(username)
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
        do {
            let result = try await repository.draw(token: token)
            guard account == username else { return nil }
            snapshot = result.snapshot
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
        do {
            let result = try await repository.use(
                token: token,
                cardKey: item.cardKey,
                rarity: item.rarity,
                effectID: effectID,
                sourceCardKey: source?.cardKey,
                sourceRarity: source?.rarity)
            guard account == username else { return false }
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
    }
}
