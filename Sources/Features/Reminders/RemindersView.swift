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
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("新增")
        }
        .padding(.horizontal, -DS.Spacing.page)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 6) {
            switchButton(.reminder, icon: "bell.badge.fill", title: "提醒")
            switchButton(.memo, icon: "doc.text.fill", title: "备忘")
        }
        .padding(5)
        .background(DS.Palette.innerSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            scope = value
            Haptics.selection()
            Task { await reload(scope: value) }
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
            tab = kind
            Haptics.selection()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tab == kind ? .white : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background {
                    if tab == kind {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Palette.accent)
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
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            LazyVStack(spacing: 12) {
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.isOverdue ? DS.Palette.pink : DS.Palette.textSecondary)
                    }
                    if item.kind == .memo {
                        Text("更新于 \(updatedDateText)")
                            .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 32, height: 32)
                }
            }

            if !displayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownPreview(markdown: displayMarkdown)
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
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
                .font(.system(size: level == 1 ? 21 : level == 2 ? 18 : 16, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 4 : 1)
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
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
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
            .font(.system(size: 13, weight: header ? .semibold : .regular))
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

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbers([String])
    case quote(String)
    case code(String)
    case table(headers: [String], rows: [[String]])

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = headingLine(line) {
                result.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let headers = tableRow(line),
               isTableSeparator(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableRow(lines[index]), !row.isEmpty {
                    rows.append(row)
                    index += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }

            if let item = bulletLine(line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = bulletLine(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                result.append(.bullets(items))
                continue
            }

            if let item = numberLine(line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = numberLine(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                result.append(.numbers(items))
                continue
            }

            if line.hasPrefix(">") {
                var quotes: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    quotes.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(quotes.joined(separator: "\n")))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                guard !next.isEmpty,
                      headingLine(next) == nil,
                      bulletLine(next) == nil,
                      numberLine(next) == nil,
                      !next.hasPrefix(">"),
                      !next.hasPrefix("```") else { break }
                if index + 1 < lines.count, tableRow(next) != nil, isTableSeparator(lines[index + 1]) { break }
                paragraph.append(next)
                index += 1
            }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return result
    }

    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let text = String(line.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes.count, text)
    }

    private static func bulletLine(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberLine(_ line: String) -> String? {
        guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let prefix = line[..<separator]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return nil }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func tableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableRow(line), cells.count >= 1 else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard value.count >= 3 else { return false }
            let hyphenCount = value.filter { $0 == "-" }.count
            return hyphenCount >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" }
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
