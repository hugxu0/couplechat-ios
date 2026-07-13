import Foundation

protocol PetSnapshotCaching {
    func load(username: String) -> CouplePetSnapshot?
    func save(_ snapshot: CouplePetSnapshot, username: String)
}

struct PetSnapshotCache: PetSnapshotCaching {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(username: String) -> CouplePetSnapshot? {
        guard let data = defaults.data(forKey: key(username)) else { return nil }
        return try? JSONDecoder().decode(CouplePetSnapshot.self, from: data)
    }

    func save(_ snapshot: CouplePetSnapshot, username: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key(username))
    }

    private func key(_ username: String) -> String {
        "pet.snapshot.v2.\(username)"
    }
}

@MainActor
final class DajuViewModel: ObservableObject {
    @Published private(set) var snapshot: CouplePetSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var usingCachedSnapshot = false
    @Published var errorMessage: String?
    @Published private(set) var feedback: String?

    private let repository: CouplePetRepository
    private let cache: any PetSnapshotCaching
    private var username: String?
    private var activeRefreshID: UUID?
    private var activeMutationID: UUID?
    private var stateGeneration = 0

    init(
        repository: CouplePetRepository = CouplePetRepository(),
        cache: any PetSnapshotCaching = PetSnapshotCache()
    ) {
        self.repository = repository
        self.cache = cache
    }

    func load(token: String, username: String, force: Bool = false) async {
        prepareAccount(username)
        if snapshot == nil, let cached = cache.load(username: username) {
            snapshot = cached
            usingCachedSnapshot = true
        }
        guard force || snapshot == nil || usingCachedSnapshot || errorMessage != nil else { return }
        guard activeRefreshID == nil, !isMutating else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        let generation = stateGeneration
        isLoading = snapshot == nil
        defer {
            if activeRefreshID == refreshID {
                isLoading = false
                activeRefreshID = nil
            }
        }
        do {
            let fresh = try await repository.fetch(token: token)
            guard generation == stateGeneration else { return }
            apply(fresh, username: username)
            usingCachedSnapshot = false
            errorMessage = nil
        } catch {
            guard generation == stateGeneration else { return }
            errorMessage = error.localizedDescription
            usingCachedSnapshot = snapshot != nil
        }
    }

    func interact(kind: PetInteractionKind, token: String, username: String) async {
        guard let pet = snapshot?.pet else { return }
        let succeeded = await mutate(token: token, username: username) {
            try await repository.interact(
                kind: kind,
                baseVersion: pet.version,
                token: token)
        }
        if succeeded { feedback = kind.confirmation }
    }

    private func prepareAccount(_ account: String) {
        guard username != account else { return }
        username = account
        stateGeneration += 1
        activeRefreshID = nil
        activeMutationID = nil
        isLoading = false
        isMutating = false
        snapshot = nil
        errorMessage = nil
        feedback = nil
        usingCachedSnapshot = false
    }

    private func mutate(
        token: String,
        username: String,
        operation: () async throws -> CouplePetSnapshot
    ) async -> Bool {
        guard activeMutationID == nil else { return false }
        let mutationID = UUID()
        activeMutationID = mutationID
        isMutating = true
        stateGeneration += 1
        let generation = stateGeneration
        defer {
            if activeMutationID == mutationID {
                activeMutationID = nil
                isMutating = false
            }
        }
        do {
            let updated = try await operation()
            guard generation == stateGeneration, self.username == username else { return false }
            apply(updated, username: username)
            errorMessage = nil
            return true
        } catch CouplePetRepositoryError.conflict {
            guard generation == stateGeneration, self.username == username else { return false }
            await recoverFromConflict(token: token, username: username)
            return false
        } catch {
            guard generation == stateGeneration, self.username == username else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func recoverFromConflict(token: String, username: String) async {
        errorMessage = CouplePetRepositoryError.conflict.localizedDescription
        let generation = stateGeneration
        guard let fresh = try? await repository.fetch(token: token) else { return }
        guard generation == stateGeneration, self.username == username else { return }
        apply(fresh, username: username)
        usingCachedSnapshot = false
    }

    private func apply(_ value: CouplePetSnapshot, username: String) {
        snapshot = value
        cache.save(value, username: username)
    }
}
