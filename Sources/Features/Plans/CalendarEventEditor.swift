import SwiftUI

struct CalendarEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    let mode: CalendarEditorMode
    let scope: String
    let onSave: (CalendarEventDraft) async -> Bool

    @State private var title: String
    @State private var notes: String
    @State private var startDate: Date
    @State private var hasEnd: Bool
    @State private var endDate: Date
    @State private var allDay: Bool
    @State private var saving = false

    init(mode: CalendarEditorMode, scope: String, onSave: @escaping (CalendarEventDraft) async -> Bool) {
        self.mode = mode
        self.scope = scope
        self.onSave = onSave
        let event = mode.event
        let initialStart = event?.startDate ?? mode.createDate ?? Date()
        _title = State(initialValue: event?.title ?? "")
        _notes = State(initialValue: event?.notes ?? "")
        _startDate = State(initialValue: initialStart)
        _hasEnd = State(initialValue: event?.endDate != nil)
        _endDate = State(initialValue: event?.endDate ?? initialStart.addingTimeInterval(3_600))
        _allDay = State(initialValue: event?.isAllDay ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("安排") {
                    TextField("日程标题", text: $title)
                    Toggle("全天", isOn: $allDay)
                    DatePicker(
                        "开始", selection: $startDate,
                        displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("设置结束时间", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker(
                            "结束", selection: $endDate,
                            in: startDate...,
                            displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    }
                }
                Section("说明") {
                    TextField("地点、约定或想一起做的事", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    Label(scope == "shared" ? "两人共享并同步到所有设备" : "仅创建者可见", systemImage: scope == "shared" ? "person.2.fill" : "person.fill")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .navigationTitle(mode.event == nil ? "新建日程" : "编辑日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task {
                            saving = true
                            if await onSave(draft) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || saving || (hasEnd && endDate < startDate))
                }
            }
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: CalendarEventDraft {
        CalendarEventDraft(
            title: trimmedTitle,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: startDate,
            endDate: hasEnd ? endDate : nil,
            isAllDay: allDay)
    }
}

private extension CalendarEditorMode {
    var event: CalendarEvent? {
        if case .edit(let event) = self { return event }
        return nil
    }
    var createDate: Date? {
        if case .create(let date) = self { return date }
        return nil
    }
}
