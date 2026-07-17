import Foundation

@MainActor
final class AppBadgeState: ObservableObject {
    static let shared = AppBadgeState()

    @Published private(set) var reminderCount = 0
    @Published private(set) var recommendationCount = 0

    private let repository = PersonalItemsRepository()
    private let recommendationRepository = RecommendationRepository()

    private init() {}

    func refreshReminders(token: String) async {
        async let personal = repository.fetch(kind: .reminder, scope: "personal", token: token)
        async let shared = repository.fetch(kind: .reminder, scope: "shared", token: token)
        let (personalItems, sharedItems) = await (personal, shared)
        let reminders = personalItems + sharedItems
        let now = Date()
        reminderCount = reminders.filter { item in
            guard !item.isDone, let due = item.dueDate else { return false }
            return due <= now || Calendar.current.isDateInToday(due)
        }.count
    }

    func refreshRecommendations(token: String) async {
        guard let count = try? await recommendationRepository.unreadCount(token: token) else { return }
        recommendationCount = max(0, count)
    }

    func reset() {
        reminderCount = 0
        recommendationCount = 0
    }
}
