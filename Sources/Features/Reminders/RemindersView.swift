import SwiftUI

struct RemindersView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var tab: PersonalItemKind = .reminder
    @State private var scope = "personal"
    @State private var items: [PersonalItem] = []
    @State private var loading = false
    @State private var editorMode: EditorMode?
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
                VStack(alignment: .leading, spacing: 16) {
                    header
                    tabSwitcher
                    scopePicker
                    summaryStrip
                    itemList
                }
                .padding(.horizontal, DS.Spacing.page)
                    .padding(.top, 12)
                    .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await reload() }
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: ChatStore.personalItemChangedNotification)) { _ in
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tab == .reminder ? "提醒事项" : "备忘录")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(scope == "shared" ? "共享\(tab == .reminder ? "提醒" : "备忘录")" : (store.session?.name ?? "我的空间"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Spacer()

            Button {
                Haptics.medium()
                editorMode = .create(tab)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(DS.Palette.accentGradient)
                    .clipShape(Circle())
                    .shadow(color: DS.Palette.accent.opacity(0.24), radius: 12, y: 6)
            }
            .buttonStyle(PressableStyle())
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 6) {
            switchButton(.reminder, icon: "bell.badge.fill", title: "提醒")
            switchButton(.memo, icon: "doc.text.fill", title: "备忘")
        }
        .padding(5)
        .background(DS.Palette.innerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var scopePicker: some View {
        HStack(spacing: 6) {
            scopeButton("personal", icon: "person.fill", title: "我的")
            scopeButton("shared", icon: "person.2.fill", title: "共享")
        }
        .padding(5)
        .background(DS.Palette.innerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func scopeButton(_ value: String, icon: String, title: String) -> some View {
        Button {
            if scope == value { return }
            withAnimation(DS.Anim.spring) { scope = value }
            Haptics.selection()
            loading = false
            Task { await reload() }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(scope == value ? .white : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background {
                    if scope == value {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(value == "shared" ? DS.Palette.purple : DS.Palette.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func switchButton(_ kind: PersonalItemKind, icon: String, title: String) -> some View {
        Button {
            if tab == kind { return }
            withAnimation(DS.Anim.spring) { tab = kind }
            Haptics.selection()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tab == kind ? .white : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    if tab == kind {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DS.Palette.accentGradient)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var summaryStrip: some View {
        HStack(spacing: 10) {
            metricTile(title: "待办", value: "\(reminders.filter { !$0.isDone }.count)", color: DS.Palette.accent)
            metricTile(title: "今日", value: "\(reminders.filter { $0.isToday }.count)", color: DS.Palette.blue)
            metricTile(title: "备忘", value: "\(memos.count)", color: DS.Palette.pink)
        }
    }

    private func metricTile(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DS.Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: 10, y: 4)
    }

    @ViewBuilder
    private var itemList: some View {
        if loading && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if visibleItems.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 12) {
                ForEach(visibleItems) { item in
                    PersonalItemCard(item: item) {
                        editorMode = .edit(item)
                    } onToggleDone: {
                        Task { await toggleDone(item) }
                    } onDelete: {
                        Task { await delete(item) }
                    }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(DS.Anim.spring, value: visibleItems)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Palette.pink)
                .padding(.horizontal, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: tab == .reminder ? "bell.slash.fill" : "text.book.closed.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)
            Text(scope == "shared"
                 ? (tab == .reminder ? "还没有共享提醒" : "还没有共享备忘录")
                 : (tab == .reminder ? "还没有提醒" : "还没有备忘录"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
            Button {
                editorMode = .create(tab)
            } label: {
                Label(tab == .reminder ? "添加提醒" : "写备忘录", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(DS.Palette.accentGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 46)
        .background(DS.Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        let fetched = await store.fetchPersonalItems(scope: scope)
        await MainActor.run {
            if scope == "personal" {
                // 合并：保留已有 shared items，替换 personal items
                let shared = items.filter { $0.scope == "shared" }
                items = fetched + shared
            } else {
                // 合并：保留已有 personal items，替换 shared items
                let personal = items.filter { $0.scope == "personal" }
                items = personal + fetched
            }
            loading = false
        }
        if let account = store.session?.username {
            await ReminderNotificationScheduler.rescheduleAll(items, account: account)
        }
    }

    private func save(mode: EditorMode, title: String, markdown: String, dueAt: Int?) async {
        errorMessage = nil
        let saved: PersonalItem?
        switch mode {
        case .create(let kind):
            saved = await store.createPersonalItem(kind: kind, scope: scope, title: title, bodyMarkdown: markdown, dueAt: dueAt)
        case .edit(let item):
            saved = await store.updatePersonalItem(
                item,
                title: title,
                bodyMarkdown: markdown,
                dueAt: dueAt,
                clearsDueAt: dueAt == nil && item.kind == .reminder,
                isDone: item.isDone)
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
        guard let updated = await store.updatePersonalItem(item, isDone: !item.isDone) else { return }
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
        guard await store.deletePersonalItem(item) else { return }
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

private enum EditorMode: Identifiable {
    case create(PersonalItemKind)
    case edit(PersonalItem)

    var id: String {
        switch self {
        case .create(let kind): return "create-\(kind.rawValue)"
        case .edit(let item): return "edit-\(item.id)"
        }
    }

    var kind: PersonalItemKind {
        switch self {
        case .create(let kind): return kind
        case .edit(let item): return item.kind
        }
    }

    var item: PersonalItem? {
        if case .edit(let item) = self { return item }
        return nil
    }
}

private struct PersonalItemCard: View {
    let item: PersonalItem
    let onEdit: () -> Void
    let onToggleDone: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if item.kind == .reminder {
                    Button(action: onToggleDone) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(item.isDone ? DS.Palette.green : DS.Palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(item.isDone ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                            .strikethrough(item.isDone)

                        if item.scope == "shared" {
                            Text(AccountPresentation.avatar(for: item.owner))
                                .font(.system(size: 14))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if item.kind == .reminder, let dueDate = item.dueDate {
                        Label(dueDate.smartLabel, systemImage: item.isOverdue ? "exclamationmark.circle.fill" : "clock.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.isOverdue ? DS.Palette.pink : DS.Palette.textSecondary)
                    }
                }

                Menu {
                    Button("编辑", action: onEdit)
                    if item.kind == .reminder {
                        Button(item.isDone ? "标记未完成" : "标记完成", action: onToggleDone)
                    }
                    Button("删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }

            if !item.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownPreview(markdown: item.bodyMarkdown)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(item.kind == .memo ? 8 : 3)
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: 12, y: 5)
        .opacity(item.isDone ? 0.68 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onEdit)
    }
}

private struct PersonalItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    let mode: EditorMode
    let scope: String
    let onSave: (String, String, Int?) -> Void

    @State private var title: String
    @State private var markdown: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var preview = false

    init(mode: EditorMode, scope: String = "personal", onSave: @escaping (String, String, Int?) -> Void) {
        self.mode = mode
        self.scope = scope
        self.onSave = onSave
        let item = mode.item
        _title = State(initialValue: item?.title ?? "")
        _markdown = State(initialValue: item?.bodyMarkdown ?? "")
        _hasDueDate = State(initialValue: item?.dueAt != nil || mode.kind == .reminder)
        _dueDate = State(initialValue: item?.dueDate ?? Date().addingTimeInterval(30 * 60))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField(mode.kind == .reminder ? "提醒标题" : "备忘标题", text: $title)
                        .font(.system(size: 24, weight: .bold))
                        .padding(16)
                        .background(DS.Palette.innerSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if mode.kind == .reminder {
                        VStack(spacing: 12) {
                            Toggle("通知提醒", isOn: $hasDueDate)
                                .font(.system(size: 15, weight: .semibold))
                            if hasDueDate {
                                DatePicker("时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.compact)
                            }
                        }
                        .padding(16)
                        .background(DS.Palette.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    HStack {
                        Text("正文")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DS.Palette.textPrimary)
                        Spacer()
                        Button(preview ? "编辑" : "预览") {
                            preview.toggle()
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }

                    if preview {
                        MarkdownPreview(markdown: markdown.isEmpty ? " " : markdown)
                            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                            .padding(16)
                            .background(DS.Palette.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        TextEditor(text: $markdown)
                            .font(.system(size: 16))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                            .padding(12)
                            .background(DS.Palette.cardSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(DS.Spacing.page)
            }
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .navigationTitle(mode.item == nil ? "新建" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dueAt = mode.kind == .reminder && hasDueDate ? Int(dueDate.timeIntervalSince1970 * 1000) : nil
                        onSave(trimmed, markdown, dueAt)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .font(.system(size: 16, weight: .bold))
                }
            }
        }
    }
}

private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: markdown) {
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension PersonalItem {
    var isToday: Bool {
        guard let dueDate else { return false }
        return Calendar.current.isDateInToday(dueDate)
    }
}

private extension Date {
    var smartLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(self) {
            formatter.dateFormat = "今天 HH:mm"
        } else if Calendar.current.isDateInTomorrow(self) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: self)
    }
}
