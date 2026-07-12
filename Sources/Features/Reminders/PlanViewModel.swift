import Foundation

enum PlanSection: String, CaseIterable, Identifiable {
    case calendar
    case reminder
    case memo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: return "日程"
        case .reminder: return "提醒"
        case .memo: return "备忘"
        }
    }
    var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .reminder: return "bell.badge.fill"
        case .memo: return "doc.text.fill"
        }
    }
}

struct CalendarEventDraft {
    var title: String
    var notes: String
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
}

enum CalendarEditorMode: Identifiable {
    case create(Date)
    case edit(CalendarEvent)

    var id: String {
        switch self {
        case .create(let date): return "create-\(date.timeIntervalSince1970)"
        case .edit(let event): return "edit-\(event.id)"
        }
    }
}

@MainActor
final class PlanViewModel: ObservableObject {
    @Published private(set) var items: [PersonalItem] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var loading = false
    @Published var errorMessage: String?

    private let personalRepository: PersonalItemsRepository
    private let calendarRepository: CalendarRepository

    init(
        personalRepository: PersonalItemsRepository = PersonalItemsRepository(),
        calendarRepository: CalendarRepository = CalendarRepository()
    ) {
        self.personalRepository = personalRepository
        self.calendarRepository = calendarRepository
    }

    func load(scope: String, around date: Date, token: String) async {
        loading = true
        errorMessage = nil
        async let personal = personalRepository.fetch(scope: scope, token: token)
        do {
            async let calendar = calendarRepository.events(
                monthContaining: date, token: token)
            let (newItems, newEvents) = try await (personal, calendar)
            replaceItems(newItems, scope: scope)
            events = newEvents
        } catch {
            replaceItems(await personal, scope: scope)
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func visibleItems(kind: PersonalItemKind, scope: String) -> [PersonalItem] {
        items.filter { $0.kind == kind && $0.scope == scope }.sorted { lhs, rhs in
            if kind == .memo { return lhs.updatedAt > rhs.updatedAt }
            switch (lhs.dueAt, rhs.dueAt) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    func events(on date: Date, scope: String) -> [CalendarEvent] {
        events.filter { $0.scope == scope && Calendar.current.isDate($0.startDate, inSameDayAs: date) }
            .sorted { $0.startAt < $1.startAt }
    }

    func saveItem(
        mode: ReminderEditorMode,
        scope: String,
        title: String,
        markdown: String,
        dueAt: Int?,
        token: String
    ) async -> Bool {
        let saved: PersonalItem?
        switch mode {
        case .create(let kind):
            saved = await personalRepository.create(
                kind: kind, scope: scope, title: title,
                bodyMarkdown: markdown, dueAt: dueAt, token: token)
        case .edit(let item):
            saved = await personalRepository.update(
                item, title: title, bodyMarkdown: markdown, dueAt: dueAt,
                clearsDueAt: dueAt == nil && item.kind == .reminder,
                isDone: item.isDone, token: token)
        }
        guard let saved else {
            errorMessage = "保存失败，请稍后再试"
            return false
        }
        upsert(saved)
        return true
    }

    func toggleItem(_ item: PersonalItem, token: String) async {
        guard let updated = await personalRepository.update(item, isDone: !item.isDone, token: token) else {
            errorMessage = "更新失败，请稍后再试"
            return
        }
        upsert(updated)
    }

    func deleteItem(_ item: PersonalItem, token: String) async {
        guard await personalRepository.delete(item, token: token) else {
            errorMessage = "删除失败，请稍后再试"
            return
        }
        items.removeAll { $0.id == item.id }
    }

    func saveEvent(
        mode: CalendarEditorMode,
        draft: CalendarEventDraft,
        scope: String,
        token: String
    ) async -> Bool {
        let range = normalizedRange(for: draft)
        let startAt = Int(range.start.timeIntervalSince1970 * 1_000)
        let endAt = range.end.map { Int($0.timeIntervalSince1970 * 1_000) }
        do {
            let saved: CalendarEvent
            switch mode {
            case .create:
                saved = try await calendarRepository.create(
                    title: draft.title, notes: draft.notes, startAt: startAt, endAt: endAt,
                    isAllDay: draft.isAllDay, scope: scope, token: token)
            case .edit(let event):
                saved = try await calendarRepository.update(
                    event, title: draft.title, notes: draft.notes,
                    startAt: startAt, endAt: endAt,
                    isAllDay: draft.isAllDay, token: token)
            }
            upsert(saved)
            return true
        } catch V2RepositoryError.calendarConflict(let current) {
            upsert(current)
            errorMessage = V2RepositoryError.calendarConflict(current).localizedDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleEvent(_ event: CalendarEvent, token: String) async {
        do {
            upsert(try await calendarRepository.setCompleted(
                event, completed: !event.isDone, token: token))
        } catch V2RepositoryError.calendarConflict(let current) {
            upsert(current)
            errorMessage = V2RepositoryError.calendarConflict(current).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteEvent(_ event: CalendarEvent, token: String) async {
        do {
            try await calendarRepository.delete(event, token: token)
            events.removeAll { $0.id == event.id }
        } catch V2RepositoryError.calendarConflict(let current) {
            upsert(current)
            errorMessage = V2RepositoryError.calendarConflict(current).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upsert(_ item: PersonalItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
    }

    private func upsert(_ event: CalendarEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) { events[index] = event }
        else { events.append(event) }
    }

    private func replaceItems(_ values: [PersonalItem], scope: String) {
        items = items.filter { $0.scope != scope } + values
    }

    private func normalizedRange(for draft: CalendarEventDraft) -> (start: Date, end: Date?) {
        guard draft.isAllDay else { return (draft.startDate, draft.endDate) }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: draft.startDate)
        if let selectedEnd = draft.endDate {
            let end = calendar.startOfDay(for: selectedEnd)
            if end > start { return (start, end) }
        }
        return (start, calendar.date(byAdding: .day, value: 1, to: start))
    }

}
