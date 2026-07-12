import SwiftUI

// MARK: - 日期设置（「在一起」纪念日 + 自由添加的纪念日/倒数日的增删改，统一在这里管理）

struct DateEditorSheet: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var together = Date()
    @State private var hasTogether = false
    @State private var editingAnniversary: AnniversaryEntry?
    @State private var showAddAnniversary = false

    var body: some View {
        NavigationStack {
            Form {
                Section("在一起的日子") {
                    Toggle("已设置", isOn: $hasTogether.animation())
                    if hasTogether {
                        DatePicker("纪念日", selection: $together, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section("纪念日 / 倒数日") {
                    ForEach(store.anniversaries) { entry in
                        Button {
                            Haptics.light()
                            editingAnniversary = entry
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.accent.color)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(DS.Palette.textPrimary)
                                    Text(entry.direction == .up ? "累计天数" : "倒数纪念日")
                                        .font(.system(size: 12))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                Spacer()
                                if let days = entry.days {
                                    Text("\(days)\(entry.direction == .up ? "天" : "天后")")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteAnniversaries)

                    Button {
                        Haptics.light()
                        showAddAnniversary = true
                    } label: {
                        Label("添加纪念日", systemImage: "plus.circle.fill")
                            .foregroundStyle(theme.accent.color)
                    }
                }
            }
            .navigationTitle("日期设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
            .sheet(item: $editingAnniversary) { entry in
                AnniversaryEditorSheet(entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAddAnniversary) {
                AnniversaryEditorSheet(entry: nil)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private func load() {
        let dates = store.coupleDates
        if let t = dates.together, let d = Self.formatter.date(from: t) {
            together = d
            hasTogether = true
        }
    }

    private func save() {
        Haptics.medium()
        var dates = store.coupleDates
        dates.together = hasTogether ? Self.formatter.string(from: together) : nil
        store.saveCoupleDates(dates)
    }

    private func deleteAnniversaries(at offsets: IndexSet) {
        var items = store.anniversaries
        items.remove(atOffsets: offsets)
        store.saveAnniversaries(items)
    }
}
