import SwiftUI

struct DajuDiaryView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var diaries: [DajuDiary] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var ensuring = false
    private let repository = DajuDiaryRepository()

    var body: some View {
        List {
            if loading && diaries.isEmpty {
                ProgressView("加载日记…")
            } else if let errorText, diaries.isEmpty {
                Text(errorText)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else if diaries.isEmpty {
                Text("还没有日记。过了北京时间 06:00 切日、且前一天有公聊时，大橘会自动写一篇。")
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                ForEach(diaries) { diary in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(diary.dayKey)
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                        Text(diary.title)
                            .font(DS.Typo.sectionLabel)
                        Text(diary.body)
                            .font(DS.Typo.body)
                            .foregroundStyle(DS.Palette.textPrimary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("大橘日记")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ensuring ? "生成中…" : "补昨日") {
                    Task { await ensureYesterday() }
                }
                .disabled(ensuring || store.session == nil)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        guard let token = store.session?.token else {
            loading = false
            errorText = "未登录"
            return
        }
        loading = true
        defer { loading = false }
        do {
            diaries = try await repository.list(token: token)
            errorText = nil
        } catch {
            errorText = "加载失败，请稍后重试"
        }
    }

    private func ensureYesterday() async {
        guard let token = store.session?.token else { return }
        ensuring = true
        defer { ensuring = false }
        do {
            if let diary = try await repository.ensureYesterday(token: token) {
                if !diaries.contains(where: { $0.id == diary.id }) {
                    diaries.insert(diary, at: 0)
                } else {
                    diaries = diaries.map { $0.dayKey == diary.dayKey ? diary : $0 }
                }
                errorText = nil
            } else {
                errorText = "昨日没有足够公聊材料，暂未生成"
            }
        } catch {
            errorText = "生成失败"
        }
    }
}
