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

    private func save(mode: EditorMode, title: String, markdown: String, dueAt: Int?) async {
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
    @EnvironmentObject private var store: ChatStore
    let item: PersonalItem
    let onEdit: () -> Void
    let onToggleDone: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            HStack(alignment: .top, spacing: DS.Spacing.gap) {
                if item.kind == .reminder {
                    Button(action: onToggleDone) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(DS.Typo.pageTitle.weight(.semibold))
                            .foregroundStyle(item.isDone ? DS.Palette.green : DS.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isDone ? "标记未完成" : "标记完成")
                }

                VStack(alignment: .leading, spacing: DS.Spacing.compact - 1) {
                    HStack(spacing: DS.Spacing.tight + 2) {
                        Text(item.title)
                            .font(DS.Typo.cardTitle)
                            .foregroundStyle(item.isDone ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                            .strikethrough(item.isDone)

                        if item.scope == "shared" {
                            AvatarBadge(
                                url: store.avatarURL(for: item.owner),
                                fallbackEmoji: store.avatarText(for: item.owner),
                                size: 20,
                                background: DS.Palette.innerSurface)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if item.kind == .reminder, let dueDate = item.dueDate {
                        Label(dueDate.smartLabel, systemImage: item.isOverdue ? "exclamationmark.circle.fill" : "clock.fill")
                            .font(DS.Typo.caption.weight(.semibold))
                            .foregroundStyle(item.isOverdue ? DS.Palette.pink : DS.Palette.textSecondary)
                    }
                    if item.kind == .memo {
                        Text("更新于 \(updatedDateText)")
                            .font(DS.Typo.caption.weight(.medium))
                            .foregroundStyle(DS.Palette.textSecondary)
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
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("更多操作")
            }

            if !displayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownPreview(markdown: displayMarkdown)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(item.kind == .memo ? nil : 3)
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .opacity(item.isDone ? 0.68 : 1)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .onTapGesture(perform: onEdit)
    }

    private var updatedDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(item.updatedAt) / 1000))
    }

    private var displayMarkdown: String {
        MemoDisplayFormatter.body(for: item)
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
                VStack(alignment: .leading, spacing: DS.Spacing.card - 2) {
                    TextField(mode.kind == .reminder ? "提醒标题" : "备忘标题", text: $title)
                        .font(DS.Typo.pageTitle)
                        .padding(DS.Spacing.card - 2)
                        .background(DS.Palette.fieldSurface)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                                .stroke(DS.Palette.hairline, lineWidth: 0.5)
                        }

                    if mode.kind == .reminder {
                        VStack(spacing: DS.Spacing.gap) {
                            Toggle("通知提醒", isOn: $hasDueDate)
                                .font(DS.Typo.button)
                            if hasDueDate {
                                DatePicker("时间", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                    .datePickerStyle(.compact)
                            }
                        }
                        .padding(DS.Spacing.card - 2)
                        .dsCard(radius: DS.Radius.bubble)
                    }

                    HStack {
                        Text("正文")
                            .font(DS.Typo.button)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Spacer()
                        Button(preview ? "编辑" : "预览") {
                            preview.toggle()
                        }
                        .font(DS.Typo.secondary.weight(.semibold))
                    }

                    if preview {
                        MarkdownPreview(markdown: markdown.isEmpty ? " " : markdown)
                            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                            .padding(DS.Spacing.card - 2)
                            .dsCard(radius: DS.Radius.bubble)
                    } else {
                        TextEditor(text: $markdown)
                            .font(DS.Typo.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                            .padding(DS.Spacing.gap)
                            .dsCard(radius: DS.Radius.bubble)
                    }
                }
                .padding(DS.Spacing.page)
            }
            .background(AppPageBackground())
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
                    .font(DS.Typo.button)
                }
            }
        }
    }
}

private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            inlineText(text)
                .font(level == 1 ? DS.Typo.pageTitle : (level == 2 ? DS.Typo.cardTitle : DS.Typo.button))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? DS.Spacing.tight : 1)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(DS.Palette.accent)
                        inlineText(item)
                    }
                }
            }
        case .numbers(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(DS.Palette.accent)
                            .fontWeight(.semibold)
                        inlineText(item)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(DS.Palette.accent.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.vertical, 2)
        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.gap - 2)
                .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        case .mermaid(let source):
            Text(MermaidFlowchartFormatter.render(source) ?? source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.gap)
                .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .rule:
            Divider()
                .overlay(DS.Palette.textSecondary.opacity(0.22))
        }
    }

    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        tableCell(index < headers.count ? headers[index] : "", header: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            tableCell(
                                columnIndex < row.count ? row[columnIndex] : "",
                                header: false,
                                alternate: rowIndex % 2 == 1
                            )
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ text: String, header: Bool, alternate: Bool = false) -> some View {
        inlineText(text)
            .font(header ? DS.Typo.caption.weight(.semibold) : DS.Typo.caption)
            .foregroundStyle(DS.Palette.textPrimary)
            .frame(minWidth: 92, maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                header
                    ? AnyShapeStyle(DS.Palette.accent.opacity(0.14))
                    : AnyShapeStyle(alternate ? DS.Palette.innerSurface.opacity(0.42) : DS.Palette.cardSurface.opacity(0.35))
            )
            .overlay(Rectangle().stroke(DS.Palette.textSecondary.opacity(0.16), lineWidth: 0.7))
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
