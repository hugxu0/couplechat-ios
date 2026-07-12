import SwiftUI

struct RemindersView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var model = PlanViewModel()
    @State private var section: PlanSection = .calendar
    @State private var scope = "shared"
    @State private var selectedDate = Date()
    @State private var monthMode = true
    @State private var itemEditor: ReminderEditorMode?
    @State private var eventEditor: CalendarEditorMode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    sectionPicker
                    scopePicker
                    content
                    if let error = model.errorMessage {
                        StatusBanner(text: error, kind: .error)
                    }
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await reload() }
            .refreshable { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: PersonalItemsRepository.changedNotification)) { _ in
                Task { await reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
                guard note.persistentSyncIncludes(["calendar_event", "personalItem"]) else { return }
                Task { await reload() }
            }
            .sheet(item: $itemEditor) { mode in
                PersonalItemEditor(mode: mode, scope: scope) { title, markdown, dueAt in
                    Task { await saveItem(mode, title: title, markdown: markdown, dueAt: dueAt) }
                }
            }
            .sheet(item: $eventEditor) { mode in
                CalendarEventEditor(mode: mode, scope: scope) { draft in
                    await saveEvent(mode, draft: draft)
                }
            }
        }
    }

    private var sectionPicker: some View {
        Picker("计划类型", selection: $section) {
            ForEach(PlanSection.allCases) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .accessibilityHint("在日程、提醒和备忘之间切换")
    }

    private var scopePicker: some View {
        Picker("可见范围", selection: $scope) {
            Label("共享", systemImage: "person.2.fill").tag("shared")
            Label("私人", systemImage: "person.fill").tag("personal")
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(maxWidth: 220)
        .onChange(of: scope) {
            Haptics.selection()
            Task { await reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if section == .calendar {
            PlanCalendarView(
                selectedDate: $selectedDate,
                monthMode: $monthMode,
                events: model.events.filter { $0.scope == scope },
                onMoveMonth: moveMonth,
                onCreate: { eventEditor = .create(selectedDate) },
                onEdit: { eventEditor = .edit($0) },
                onToggle: toggleEvent,
                onDelete: deleteEvent)
        } else {
            let kind: PersonalItemKind = section == .reminder ? .reminder : .memo
            PlanPersonalList(
                kind: kind,
                scope: scope,
                items: model.visibleItems(kind: kind, scope: scope),
                allItems: model.items,
                loading: model.loading,
                onCreate: { itemEditor = .create(kind) },
                onEdit: { itemEditor = .edit($0) },
                onToggle: toggleItem,
                onDelete: deleteItem)
        }
    }

    private var subtitle: String {
        scope == "shared" ? "两个人、每台设备，始终是同一份安排" : "只属于创建者的安排"
    }

    private func createCurrent() {
        Haptics.medium()
        switch section {
        case .calendar: eventEditor = .create(selectedDate)
        case .reminder: itemEditor = .create(.reminder)
        case .memo: itemEditor = .create(.memo)
        }
    }

    private func moveMonth(_ offset: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: offset, to: selectedDate) else { return }
        selectedDate = next
        Task { await reload() }
    }

    private func reload() async {
        guard let token = store.session?.token else { return }
        await model.load(scope: scope, around: selectedDate, token: token)
    }

    private func saveItem(_ mode: ReminderEditorMode, title: String, markdown: String, dueAt: Int?) async {
        guard let token = store.session?.token else { return }
        if await model.saveItem(
            mode: mode, scope: scope, title: title,
            markdown: markdown, dueAt: dueAt, token: token) {
            itemEditor = nil
        }
    }

    private func saveEvent(_ mode: CalendarEditorMode, draft: CalendarEventDraft) async -> Bool {
        guard let token = store.session?.token else { return false }
        return await model.saveEvent(mode: mode, draft: draft, scope: scope, token: token)
    }

    private func toggleItem(_ item: PersonalItem) {
        guard let token = store.session?.token else { return }
        Task { await model.toggleItem(item, token: token) }
    }

    private func deleteItem(_ item: PersonalItem) {
        guard let token = store.session?.token else { return }
        Task { await model.deleteItem(item, token: token) }
    }

    private func toggleEvent(_ event: CalendarEvent) {
        guard let token = store.session?.token else { return }
        Task { await model.toggleEvent(event, token: token) }
    }

    private func deleteEvent(_ event: CalendarEvent) {
        guard let token = store.session?.token else { return }
        Task { await model.deleteEvent(event, token: token) }
    }
}
