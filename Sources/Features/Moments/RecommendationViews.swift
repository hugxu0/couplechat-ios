import SwiftUI

struct TodayRecommendationCard: View {
    let snapshot: RecommendationTodaySnapshot?
    let loading: Bool
    let refreshing: Bool
    let onRefresh: () -> Void
    let onHistory: () -> Void
    let onGift: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if loading && snapshot == nil {
                HStack(spacing: DS.Spacing.gap) {
                    ProgressView()
                    Text("大橘正在翻昨天的经历…")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            } else if let snapshot {
                recommendationBlock(
                    source: "大橘",
                    icon: AccountPresentation.dajuIconName,
                    content: snapshot.daju.content,
                    tint: DS.Palette.orange,
                    refreshing: refreshing,
                    onRefresh: onRefresh)

                if let partner = snapshot.partner {
                    recommendationBlock(
                        source: "\(partner.sourceName) 给你的",
                        icon: "gift.fill",
                        content: partner.content,
                        tint: DS.Palette.pink)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                Text("暂时没有取到今天的推荐，稍后再来看看。")
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            }
        }
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.card)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Spacing.compact) {
            Text("今日推荐")
                .font(DS.Typo.cardTitle)
                .foregroundStyle(DS.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Spacing.compact)
            iconButton(
                systemName: "clock.arrow.circlepath",
                accessibilityLabel: "推荐历史",
                action: onHistory)
            iconButton(
                systemName: "gift.fill",
                accessibilityLabel: "给 TA 推荐",
                emphasized: true,
                action: onGift)
        }
    }

    private func iconButton(
        systemName: String,
        accessibilityLabel: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(emphasized ? Color.white : DS.Palette.accent)
                .frame(width: 44, height: 44)
                .background(
                    emphasized ? DS.Palette.accent : DS.Palette.accent.opacity(0.10),
                    in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func recommendationBlock(
        source: String,
        icon: String,
        content: String,
        tint: Color,
        refreshing: Bool = false,
        onRefresh: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.gap) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                Label(source, systemImage: icon)
                    .font(DS.Typo.sectionLabel)
                    .foregroundStyle(tint)
                Text(content)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onRefresh {
                Button {
                    Haptics.selection()
                    onRefresh()
                } label: {
                    Group {
                        if refreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .accessibilityLabel("重新生成今天的推荐")
            }
        }
        .padding(14)
        .background(DS.Palette.innerSurface, in: RoundedRectangle(
            cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(tint.opacity(0.22))
                .padding(10)
                .allowsHitTesting(false)
        }
    }
}

struct RecommendationComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var content = ""
    @State private var sending = false
    @State private var errorMessage: String?

    let partnerName: String
    let onSend: (String) async -> Bool

    private var normalizedContent: String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.section) {
                ZStack(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("想给 \(partnerName) 推荐什么？")
                            .font(DS.Typo.body)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $content)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .focused($focused)
                        .accessibilityLabel("推荐内容")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(DS.Palette.fieldSurface, in: RoundedRectangle(
                    cornerRadius: DS.Radius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .stroke(DS.Palette.hairline, lineWidth: 0.5)
                }

                HStack {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.red)
                    }
                    Spacer()
                    Text("\(content.count) / 500")
                        .font(DS.Typo.caption.monospacedDigit())
                        .foregroundStyle(DS.Palette.textTertiary)
                }

                AppPrimaryButton(
                    title: "推荐给 \(partnerName)",
                    busy: sending,
                    enabled: !normalizedContent.isEmpty
                ) {
                    Task { await send() }
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.page)
            .background(AppPageBackground())
            .navigationTitle("给 TA 推荐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onChange(of: content) { _, value in
                if value.count > 500 { content = String(value.prefix(500)) }
            }
        }
    }

    private func send() async {
        guard !sending, !normalizedContent.isEmpty else { return }
        sending = true
        errorMessage = nil
        let sent = await onSend(normalizedContent)
        sending = false
        if sent {
            Haptics.medium()
            dismiss()
        } else {
            errorMessage = "这次没有送达，请稍后再试"
        }
    }
}

struct ReceivedRecommendationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var handled = false

    let item: RecommendationItem
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.section) {
            Spacer(minLength: 4)
            Image(systemName: "gift.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(DS.Palette.pink)
                .frame(width: 72, height: 72)
                .background(DS.Palette.pink.opacity(0.12), in: Circle())
            VStack(spacing: 8) {
                Text("\(item.sourceName) 今天给你推荐了")
                    .font(DS.Typo.cardTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(item.content)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.card)
            .background(DS.Palette.innerSurface, in: RoundedRectangle(
                cornerRadius: DS.Radius.panel, style: .continuous))
            Spacer(minLength: 8)
            AppPrimaryButton(title: "收下啦") { finish() }
        }
        .padding(DS.Spacing.page)
        .background(AppPageBackground())
        .onDisappear { acknowledgeIfNeeded() }
    }

    private func finish() {
        acknowledgeIfNeeded()
        Haptics.medium()
        dismiss()
    }

    private func acknowledgeIfNeeded() {
        guard !handled else { return }
        handled = true
        onDismiss()
    }
}

struct RecommendationHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RecommendationHistoryViewModel()
    @State private var pendingDelete: RecommendationItem?

    let token: String

    var body: some View {
        NavigationStack {
            Group {
                if model.loading && model.items.isEmpty {
                    ProgressView("正在整理推荐历史…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "还没有推荐历史",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("大橘和你们的推荐会保存在这里。"))
                } else {
                    List {
                        ForEach(model.items) { item in
                            RecommendationHistoryRow(item: item)
                                .listRowBackground(DS.Palette.cardSurface)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = item
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                .task { await model.loadMoreIfNeeded(item: item, token: token) }
                        }
                        if model.loadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                        }
                        if let errorMessage = model.errorMessage {
                            StatusBanner(text: errorMessage, kind: .error)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .refreshable { await model.load(token: token, force: true) }
                }
            }
            .background(AppPageBackground())
            .navigationTitle("推荐历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await model.load(token: token) }
            .confirmationDialog(
                "删除这条历史推荐？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    guard let item = pendingDelete else { return }
                    pendingDelete = nil
                    Task { await model.delete(item, token: token) }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("只会从你的推荐历史中移除，不影响 TA 的记录。")
            }
        }
    }
}
