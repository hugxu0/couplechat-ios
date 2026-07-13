import SwiftUI

// MARK: - 推荐输入弹层（自己写一条推荐发给对方）

struct RecommendComposerSheet: View {
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeManager
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("推荐点什么给 TA？")
                    .font(DS.Typo.pageTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("一首歌、一部电影、一家店…TA 打开记录页就会看到")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)

                TextField("比如：新出的那部电影超好看，周末一起？", text: $text, axis: .vertical)
                    .focused($focused)
                    .lineLimit(3...6)
                    .font(DS.Typo.body)
                    .padding(DS.Spacing.card - 4)
                    .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: DS.Radius.bubble - 2, style: .continuous))

                Button {
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { return }
                    Haptics.medium()
                    onSend(String(body.prefix(120)))
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gift.fill")
                            .font(DS.Typo.button)
                        Text("送出推荐")
                            .font(DS.Typo.button)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.accent.gradient, in: RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.section)
            .background(AppPageBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }
}
