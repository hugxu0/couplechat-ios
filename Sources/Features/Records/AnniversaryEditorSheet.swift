import SwiftUI

// MARK: - 自由添加的纪念日 / 倒数日编辑

struct AnniversaryEditorSheet: View {
    let entry: AnniversaryEntry?

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var date = Date()
    @State private var direction: AnniversaryEntry.Direction = .up
    @State private var icon = Self.iconOptions.first!

    private static let iconOptions = [
        "heart.fill", "gift.fill", "airplane", "birthday.cake.fill",
        "figure.2.arms.open", "moon.stars.fill", "cloud.sun", "message.fill",
    ]

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private var isEditing: Bool { entry != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("比如：纪念日 / 生日 / 旅行倒数", text: $title)
                }
                Section("类型") {
                    Picker("类型", selection: $direction) {
                        Text("累计天数").tag(AnniversaryEntry.Direction.up)
                        Text("倒数纪念日").tag(AnniversaryEntry.Direction.down)
                    }
                    .pickerStyle(.segmented)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                }
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { name in
                            Button {
                                Haptics.selection()
                                icon = name
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(icon == name ? .white : theme.accent.color)
                                    .frame(width: 44, height: 44)
                                    .background(icon == name ? AnyShapeStyle(theme.accent.color) : AnyShapeStyle(theme.accent.color.opacity(0.12)))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.vertical, 6)
                }
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            Haptics.medium()
                            deleteEntry()
                            dismiss()
                        } label: {
                            Text("删除纪念日")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑纪念日" : "添加纪念日")
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
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let entry else { return }
        title = entry.title
        direction = entry.direction
        icon = entry.icon
        if let d = Self.formatter.date(from: entry.date) {
            date = d
        }
    }

    private func save() {
        Haptics.medium()
        var items = store.anniversaries
        let dateString = Self.formatter.string(from: date)
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if let entry, let idx = items.firstIndex(where: { $0.id == entry.id }) {
            items[idx] = AnniversaryEntry(id: entry.id, title: trimmedTitle, date: dateString, direction: direction, icon: icon)
        } else {
            items.append(AnniversaryEntry(title: trimmedTitle, date: dateString, direction: direction, icon: icon))
        }
        store.saveAnniversaries(items)
    }

    private func deleteEntry() {
        guard let entry else { return }
        var items = store.anniversaries
        items.removeAll { $0.id == entry.id }
        store.saveAnniversaries(items)
    }
}
