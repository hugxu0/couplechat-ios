import SwiftUI

struct PlansView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var model = PlansViewModel()
    @State private var section: PlanSection = .calendar
    @State private var scope = "shared"
    @State private var selectedDate = Date()
    @State private var monthMode = true
    @State private var itemEditor: PlanEditorMode?
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
        PlanSegmentedControl(
            options: PlanSection.allCases,
            selection: $section,
            title: { $0.title },
            accent: theme.accent.color,
            height: 50)
        .onChange(of: section) {
            Haptics.selection()
        }
        .accessibilityHint("在日程、提醒和备忘之间切换")
    }

    private var scopePicker: some View {
        PlanSegmentedControl(
            options: ["shared", "personal"],
            selection: $scope,
            title: { $0 == "shared" ? "共享" : "私人" },
            accent: DS.Palette.purple,
            height: 42)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity, alignment: .center)
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

    private func saveItem(_ mode: PlanEditorMode, title: String, markdown: String, dueAt: Int?) async {
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

private struct PlanSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    let accent: Color
    let height: CGFloat

    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    guard selection != option else { return }
                    withAnimation(DS.Anim.springFast) { selection = option }
                } label: {
                    Text(title(option))
                        .font(DS.Typo.button)
                        .foregroundStyle(selection == option ? Color.white : DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .background {
                            if selection == option {
                                Capsule(style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [accent.opacity(0.98), accent.opacity(0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .stroke(.white.opacity(0.35), lineWidth: 0.7)
                                    }
                                    .shadow(color: accent.opacity(0.24), radius: 7, y: 3)
                                    .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: height)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(DS.Palette.textTertiary.opacity(0.15), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.045), radius: 9, y: 4)
    }
}
