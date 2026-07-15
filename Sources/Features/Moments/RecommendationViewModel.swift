import Foundation

@MainActor
final class RecommendationViewModel: ObservableObject {
    @Published private(set) var today: RecommendationTodaySnapshot?
    @Published private(set) var loading = false
    @Published private(set) var refreshing = false
    @Published private(set) var sending = false
    @Published var errorMessage: String?

    private let repository: RecommendationRepository

    init(repository: RecommendationRepository = RecommendationRepository()) {
        self.repository = repository
    }

    @discardableResult
    func load(token: String) async -> RecommendationItem? {
        guard !loading else { return today?.latestUnread }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let snapshot = try await repository.today(token: token)
            today = snapshot
            return snapshot.latestUnread
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func refresh(token: String) async {
        guard !refreshing else { return }
        refreshing = true
        errorMessage = nil
        defer { refreshing = false }
        do {
            let item = try await repository.refresh(token: token)
            if today == nil {
                _ = await load(token: token)
            } else {
                today?.daju = item
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ content: String, token: String) async -> Bool {
        guard !sending else { return false }
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            _ = try await repository.send(content, token: token)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func markRead(_ item: RecommendationItem, token: String) async {
        do {
            try await repository.markRead(item.id, token: token)
            today?.latestUnread = nil
            today?.unreadCount = 0
            if today?.partner?.id == item.id {
                today?.partner?.isRead = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class RecommendationHistoryViewModel: ObservableObject {
    @Published private(set) var items: [RecommendationItem] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published var errorMessage: String?

    private let repository: RecommendationRepository
    private var nextCursor: String?
    private var hasMore = true

    init(repository: RecommendationRepository = RecommendationRepository()) {
        self.repository = repository
    }

    func load(token: String, force: Bool = false) async {
        guard !loading else { return }
        if !force && !items.isEmpty { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let page = try await repository.history(token: token)
            items = page.recommendations
            nextCursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(item: RecommendationItem, token: String) async {
        guard hasMore, items.last?.id == item.id,
              let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await repository.history(cursor: cursor, token: token)
            items.append(contentsOf: page.recommendations.filter { next in
                !items.contains(where: { $0.id == next.id })
            })
            nextCursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: RecommendationItem, token: String) async {
        do {
            try await repository.deleteFromHistory(item.id, token: token)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
