import SwiftUI

struct PersonalItemEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ChatStore
    let mode: PlanEditorMode
    let scope: String
    let onSave: (String, String, Int?) -> Void

    @State private var title: String
    @State private var markdown: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var preview = false

    init(mode: PlanEditorMode, scope: String = "personal", onSave: @escaping (String, String, Int?) -> Void) {
        self.mode = mode
        self.scope = scope
        self.onSave = onSave
        let item = mode.item
        _title = State(initialValue: item?.title ?? "")
        _markdown = State(initialValue: item?.bodyMarkdown ?? "")
        // 编辑既有条目时按它自己有没有到期时间决定；只有新建提醒才默认打开。
        // 否则编辑一条没有到期时间的提醒会凭空补上一个时间并触发推送。
        _hasDueDate = State(initialValue: item.map { $0.dueAt != nil } ?? (mode.kind == .reminder))
        _dueDate = State(initialValue: item?.dueDate ?? Date().addingTimeInterval(30 * 60))
    }

    private var barkConfigured: Bool {
        guard let username = store.auth.session?.username else { return true }
        return BarkSettingsSheet.isConfigured(for: username)
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
                                if !barkConfigured {
                                    // Bark 是唯一推送通道；没配置时到点静默，必须提前说清。
                                    Label("这台设备还没配置离线通知，提醒到点不会收到推送。可在「我的 → 离线通知」设置 Bark。", systemImage: "bell.slash")
                                        .font(DS.Typo.caption)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
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
                        PlanMarkdownPreview(markdown: markdown.isEmpty ? " " : markdown)
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
