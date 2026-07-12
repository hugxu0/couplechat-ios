import SwiftUI

struct RemindersView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var tab: PersonalItemKind = .reminder
    @State private var scope = "personal"
    @State private var items: [PersonalItem] = []
    @State private var loading = false
    @State private var editorMode: ReminderEditorMode?
    @State private var errorMessage: String?

    private var reminders: [PersonalItem] {
        items
            .filter { $0.kind == .reminder && $0.scope == scope }
            .sorted {
                switch ($0.dueAt, $1.dueAt) {
                case let (a?, b?): return a < b
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.updatedAt > $1.updatedAt
                }
            }
    }

    private var memos: [PersonalItem] {
        items
            .filter { $0.kind == .memo && $0.scope == scope }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visibleItems: [PersonalItem] {
        tab == .reminder ? reminders : memos
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.card - 2) {
                    header
                    tabSwitcher
                    scopePicker
                    summaryStrip
                    itemList
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, DS.Spacing.gap)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: PersonalItemsRepository.changedNotification)) { _ in
                Task { await reload() }
            }
            .sheet(item: $editorMode) { mode in
                PersonalItemEditor(mode: mode, scope: scope) { title, markdown, dueAt in
                    Task { await save(mode: mode, title: title, markdown: markdown, dueAt: dueAt) }
                }
            }
        }
    }

    private var header: some View {
        RootPageHeader(
            tab == .reminder ? "提醒事项" : "备忘录",
            subtitle: scope == "shared"
                ? "共享\(tab == .reminder ? "提醒" : "备忘录")"
                : (store.auth.session?.name ?? "我的空间")
        ) {
            Button {
                Haptics.medium()
                editorMode = .create(tab)
            } label: {
                Image(systemName: "plus")
                    .font(DS.Typo.button)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("新增")
        }
        .padding(.horizontal, -DS.Spacing.page)
    }

    private var tabSwitcher: some View {
        HStack(spacing: DS.Spacing.tight + 2) {
            switchButton(.reminder, icon: "bell.badge.fill", title: "提醒")
            switchButton(.memo, icon: "doc.text.fill", title: "备忘")
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.tight + 1)
        .background(DS.Palette.innerSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
    }

    private var scopePicker: some View {
        HStack(spacing: DS.Spacing.tight + 2) {
            scopeButton("personal", icon: "person.fill", title: "我的")
            scopeButton("shared", icon: "person.2.fill", title: "共享")
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.tight + 1)
        .background(DS.Palette.innerSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
    }

    private func scopeButton(_ value: String, icon: String, title: String) -> some View {
        Button {
            if scope == value { return }
            scope = value
            Haptics.selection()
            Task { await reload(scope: value) }
        } label: {
            Label(title, systemImage: icon)
                .font(DS.Typo.button)
                .foregroundStyle(scope == value ? .white : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
                .background {
                    if scope == value {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(value == "shared" ? DS.Palette.purple : DS.Palette.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    private func switchButton(_ kind: PersonalItemKind, icon: String, title: String) -> some View {
        Button {
            if tab == kind { return }
            tab = kind
            Haptics.selection()
        } label: {
            Label(title, systemImage: icon)
                .font(DS.Typo.button)
                .foregroundStyle(tab == kind ? .white : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
                .background {
                    if tab == kind {
                        RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                            .fill(DS.Palette.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }

    private var summaryStrip: some View {
        HStack(spacing: DS.Spacing.gap - 2) {
            metricTile(title: "待办", value: "\(reminders.filter { !$0.isDone }.count)", color: DS.Palette.accent)
            metricTile(title: "今日", value: "\(reminders.filter { $0.isToday }.count)", color: DS.Palette.blue)
            metricTile(title: "备忘", value: "\(memos.count)", color: DS.Palette.pink)
        }
    }

    private func metricTile(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.compact) {
            Text(value)
                .font(DS.Typo.pageTitle)
                .foregroundStyle(color)
            Text(title)
                .font(DS.Typo.caption.weight(.medium))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.card - 4)
        .dsCard(radius: DS.Radius.tile)
    }

    @ViewBuilder
    private var itemList: some View {
        if loading && visibleItems.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if visibleItems.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: DS.Spacing.gap) {
                ForEach(visibleItems) { item in
                    PersonalItemCard(item: item) {
                        editorMode = .edit(item)
                    } onToggleDone: {
                        Task { await toggleDone(item) }
                    } onDelete: {
                        Task { await delete(item) }
                    }
                }
            }
        }

        if let errorMessage {
            StatusBanner(text: errorMessage, kind: .error)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            AppEmptyState(
                scope == "shared"
                    ? (tab == .reminder ? "还没有共享提醒" : "还没有共享备忘录")
                    : (tab == .reminder ? "还没有提醒" : "还没有备忘录"),
                systemImage: tab == .reminder ? "bell.slash" : "text.book.closed")
            Button {
                editorMode = .create(tab)
            } label: {
                Label(tab == .reminder ? "添加提醒" : "写备忘录", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func reload(scope requestedScope: String? = nil) async {
        let targetScope = requestedScope ?? scope
        if scope == targetScope && !items.contains(where: { $0.scope == targetScope }) {
            loading = true
        }
        errorMessage = nil
        guard let token = store.auth.session?.token else {
            loading = false
            return
        }
        let fetched = await store.personalItems.fetch(scope: targetScope, token: token)
        await MainActor.run {
            if targetScope == "personal" {
                // 合并：保留已有 shared items，替换 personal items
                let shared = items.filter { $0.scope == "shared" }
                items = fetched + shared
            } else {
                // 合并：保留已有 personal items，替换 shared items
                let personal = items.filter { $0.scope == "personal" }
                items = personal + fetched
            }
            if scope == targetScope { loading = false }
        }
        if let account = store.session?.username {
            await ReminderNotificationScheduler.rescheduleAll(items, account: account)
        }
    }

    private func save(mode: ReminderEditorMode, title: String, markdown: String, dueAt: Int?) async {
        errorMessage = nil
        guard let token = store.auth.session?.token else { return }
        let saved: PersonalItem?
        switch mode {
        case .create(let kind):
            saved = await store.personalItems.create(
                kind: kind, scope: scope, title: title,
                bodyMarkdown: markdown, dueAt: dueAt, token: token)
        case .edit(let item):
            saved = await store.personalItems.update(
                item,
                title: title,
                bodyMarkdown: markdown,
                dueAt: dueAt,
                clearsDueAt: dueAt == nil && item.kind == .reminder,
                isDone: item.isDone,
                token: token)
        }

        guard let saved else {
            await MainActor.run { errorMessage = "保存失败，请稍后再试" }
            return
        }

        await MainActor.run {
            if let index = items.firstIndex(where: { $0.id == saved.id }) {
                items[index] = saved
            } else {
                items.append(saved)
            }
            editorMode = nil
        }

        if let account = store.session?.username {
            await ReminderNotificationScheduler.schedule(saved, account: account)
        }
    }

    private func toggleDone(_ item: PersonalItem) async {
        guard let token = store.auth.session?.token,
              let updated = await store.personalItems.update(
                item, isDone: !item.isDone, token: token) else { return }
        await MainActor.run {
            if let index = items.firstIndex(where: { $0.id == updated.id }) {
                items[index] = updated
            }
        }
        if let account = store.session?.username {
            await ReminderNotificationScheduler.schedule(updated, account: account)
        }
    }

    private func delete(_ item: PersonalItem) async {
        guard let token = store.auth.session?.token,
              await store.personalItems.delete(item, token: token) else { return }
        await MainActor.run {
            withAnimation(DS.Anim.spring) {
                items.removeAll { $0.id == item.id }
            }
        }
        if let account = store.session?.username {
            await ReminderNotificationScheduler.cancel(item, account: account)
        }
    }
}
