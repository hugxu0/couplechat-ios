import SwiftUI

struct PlansView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var model = PlansViewModel()
    @State private var section: PlanSection = .reminder
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
                    actionHeader
                    content
                    if let error = model.errorMessage {
                        StatusBanner(text: error, kind: .error)
                    }
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, 8)
                .padding(.bottom, 96)
                .appReadableWidth(980)
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
            .onReceive(NotificationCenter.default.publisher(for: .openRemindersDeepLink)) { _ in
                section = .reminder
            }
            .sheet(item: $itemEditor) { mode in
                PersonalItemEditor(mode: mode, scope: scope) { title, markdown, dueAt in
                    Task { await saveItem(mode, title: title, markdown: markdown, dueAt: dueAt) }
                }
                .presentationSizing(.form)
            }
            .sheet(item: $eventEditor) { mode in
                CalendarEventEditor(mode: mode, scope: scope) { draft in
                    await saveEvent(mode, draft: draft)
                }
                .presentationSizing(.form)
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

    private var actionHeader: some View {
        HStack(spacing: DS.Spacing.gap) {
            AppSectionHeader(title: actionTitle, subtitle: actionSubtitle)
            Spacer(minLength: 8)
            Button(action: openCreateEditor) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(section == .calendar ? DS.Palette.purple : theme.accent.color)
                    .frame(width: 44, height: 44)
                    .background(
                        (section == .calendar ? DS.Palette.purple : theme.accent.color).opacity(0.12),
                        in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(actionButtonTitle)
        }
    }

    private var actionTitle: String {
        switch section {
        case .calendar:
            return selectedDate.formatted(
                .dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
        case .reminder: return "提醒"
        case .memo: return "备忘"
        }
    }

    private var actionSubtitle: String {
        switch section {
        case .calendar: return scope == "shared" ? "为两个人安排这一天" : "安排自己的这一天"
        case .reminder: return scope == "shared" ? "双方都会收到共享提醒" : "只提醒自己"
        case .memo: return scope == "shared" ? "两个人共同整理的备忘" : "只在自己的清单中显示"
        }
    }

    private var actionButtonTitle: String {
        switch section {
        case .calendar: return "添加日程"
        case .reminder: return "添加提醒"
        case .memo: return "写备忘录"
        }
    }

    private func openCreateEditor() {
        Haptics.selection()
        switch section {
        case .calendar: eventEditor = .create(selectedDate)
        case .reminder: itemEditor = .create(.reminder)
        case .memo: itemEditor = .create(.memo)
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
                onEdit: { itemEditor = .edit($0) },
                onToggle: toggleItem,
                onDelete: deleteItem)
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
        await AppBadgeState.shared.refreshReminders(token: token)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
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
        .frame(minHeight: height)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(DS.Palette.textTertiary.opacity(0.15), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.045), radius: 9, y: 4)
    }
}
