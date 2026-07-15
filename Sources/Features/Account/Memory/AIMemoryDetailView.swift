import SwiftUI

struct AIMemoryDetailView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var item: AIMemoryItem
    @State private var draft: String
    @State private var isImportant: Bool
    @State private var sources: [AIMemorySource] = []
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var errorMessage: String?

    let onChanged: () -> Void

    init(item: AIMemoryItem, onChanged: @escaping () -> Void) {
        _item = State(initialValue: item)
        _draft = State(initialValue: item.content)
        _isImportant = State(initialValue: item.importance >= 4)
        self.onChanged = onChanged
    }

    var body: some View {
        Form {
            if let errorMessage {
                StatusBanner(text: errorMessage, kind: .error)
            }
            identitySection
            contentSection
            if item.layer == .relationship || item.layer == .insight || item.kind == .observation {
                sourceSection
            }
            informationSection
            deleteSection
        }
        .navigationTitle(item.layer.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { Task { await save() } }
                    .disabled(!canSave || isSaving)
            }
        }
        .overlay { if isSaving { ProgressView().controlSize(.large) } }
        .task {
            await loadSources()
        }
        .confirmationDialog(
            "让大橘忘掉这条记忆？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("忘掉这条记忆", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会删除记忆，不会删除聊天消息。")
        }
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: item.layer.icon)
                    .foregroundStyle(item.layer.tint)
                    .frame(width: 34, height: 34)
                    .background(item.layer.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.perspectiveTitle) · \(item.kindTitle)")
                        .font(DS.Typo.button)
                    Text("\(item.layer.title) · \(item.statusTitle)")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
    }

    private var contentSection: some View {
        Section {
            TextEditor(text: $draft)
                .frame(minHeight: 130)
                .accessibilityLabel("记忆内容")
            Toggle("标为重要", isOn: $isImportant)
        } header: {
            Text("大橘记住的内容")
        } footer: {
            Text(item.kind == .observation
                 ? "这是大橘的观察性假设，不等于主人明确说过的事实；纠正后，大橘会使用你保存的版本。"
                 : "纠正后，大橘会使用你保存的版本。")
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section("生成依据") {
            if sources.isEmpty {
                Text((item.derivedFromCount ?? 0) > 0
                     ? "正在读取…" : "暂无可显示的基础记忆")
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.content)
                            .font(DS.Typo.body)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text("\(source.layer.title) · \(sourceDate(source.occurredAt ?? source.validFrom ?? source.updatedAt))")
                            .font(DS.Typo.micro.monospacedDigit())
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var informationSection: some View {
        Section("记录信息") {
            LabeledContent("人物", value: item.subjectTitle)
            LabeledContent("记忆视角", value: item.perspectiveTitle)
            LabeledContent("记忆类型", value: item.kindTitle)
            LabeledContent("可见范围", value: item.visibilityTitle)
            LabeledContent("分类", value: item.layer.title)
            LabeledContent("状态", value: item.statusTitle)
            if item.kind == .observation {
                LabeledContent("观察置信度", value: "\(Int((item.confidence * 100).rounded()))%")
            }
            if item.layer == .event {
                LabeledContent("经历时间", value: item.eventTimeTitle)
            } else {
                LabeledContent("最近更新", value: sourceDate(item.updatedAt))
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("忘掉这条记忆", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
    }

    private var canSave: Bool {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.count >= 3 && (content != item.content || isImportant != (item.importance >= 4))
    }

    private func loadSources() async {
        guard let token = store.session?.token, (item.derivedFromCount ?? 0) > 0 else { return }
        do {
            sources = try await store.memoryControl.sources(for: item.id, token: token)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let token = store.session?.token else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            item = try await store.memoryControl.update(
                item.id,
                content: draft,
                importance: Self.resolvedImportance(
                    original: item.importance,
                    isImportant: isImportant),
                baseVersion: item.version ?? 0,
                token: token)
            draft = item.content
            errorMessage = nil
            onChanged()
        } catch AIMemoryRepositoryError.conflict(let current) {
            item = current
            draft = current.content
            isImportant = current.importance >= 4
            errorMessage = AIMemoryRepositoryError.conflict(current).localizedDescription
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let token = store.session?.token else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.memoryControl.delete(item.id, token: token)
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sourceDate(_ milliseconds: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated static func resolvedImportance(original: Int, isImportant: Bool) -> Int {
        guard isImportant != (original >= 4) else { return original }
        return isImportant ? 5 : 3
    }
}
