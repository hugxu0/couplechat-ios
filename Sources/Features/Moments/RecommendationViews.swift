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
                    Text("大橘正在为你们挑今天的推荐…")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            } else if let snapshot {
                dajuRecommendation(snapshot.daju)

                if let partner = snapshot.partner {
                    partnerRecommendation(partner)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(emphasized ? Color.white : DS.Palette.accent)
                .frame(width: 38, height: 38)
                .background(
                    emphasized ? DS.Palette.accent : DS.Palette.accent.opacity(0.10),
                    in: Circle())
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func dajuRecommendation(_ item: RecommendationItem) -> some View {
        let category = normalizedCategory(item.category)
        let symbol = recommendationSymbol(for: category)

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.compact) {
                    categoryBadge(category, symbol: symbol)
                    Spacer(minLength: DS.Spacing.compact)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                    categoryBadge(category, symbol: symbol)
                    refreshButton
                }
            }

            Text(item.content)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Label("大橘根据你们昨天的共同经历挑选", systemImage: AccountPresentation.dajuIconName)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(15)
        .background {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [DS.Palette.accent.opacity(0.10), DS.Palette.innerSurface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: 70, weight: .regular))
                    .foregroundStyle(DS.Palette.accent.opacity(0.055))
                    .offset(x: 13, y: 13)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .stroke(DS.Palette.accent.opacity(0.10), lineWidth: 0.75)
        }
    }

    private func categoryBadge(_ category: String, symbol: String) -> some View {
        Label(category, systemImage: symbol)
            .font(DS.Typo.caption.weight(.semibold))
            .foregroundStyle(DS.Palette.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DS.Palette.accent.opacity(0.11), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("推荐分类：\(category)")
    }

    private var refreshButton: some View {
        Button {
            Haptics.selection()
            onRefresh()
        } label: {
            HStack(spacing: 6) {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(refreshing ? "在挑选" : "换一个")
            }
            .font(DS.Typo.caption.weight(.medium))
            .foregroundStyle(DS.Palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DS.Palette.cardSurface, in: Capsule())
            .contentShape(Capsule())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
        .accessibilityLabel(refreshing ? "正在重新挑选" : "换一个推荐")
    }

    private func partnerRecommendation(_ item: RecommendationItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("\(item.sourceName) 推荐给你", systemImage: "gift.fill")
                .font(DS.Typo.sectionLabel)
                .foregroundStyle(DS.Palette.pink)
            Text(item.content)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(DS.Palette.pink.opacity(0.055), in: RoundedRectangle(
            cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .stroke(DS.Palette.pink.opacity(0.10), lineWidth: 0.75)
        }
    }

    private func normalizedCategory(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return "大橘推荐" }
        return value
    }

    private func recommendationSymbol(for category: String) -> String {
        let value = category.lowercased()
        if ["电视剧", "剧集", "综艺", "动画", "动漫"].contains(where: { value.contains($0) }) {
            return "tv"
        }
        if ["电影", "影视", "纪录片", "短片"].contains(where: { value.contains($0) }) {
            return "film.stack"
        }
        if ["音乐", "歌曲", "专辑", "歌单"].contains(where: { value.contains($0) }) {
            return "music.note.list"
        }
        if ["播客", "音频", "电台"].contains(where: { value.contains($0) }) {
            return "headphones"
        }
        if ["书", "阅读", "小说", "漫画", "杂志"].contains(where: { value.contains($0) }) {
            return "book.closed"
        }
        if ["美食", "餐厅", "小吃", "甜品", "饮品", "咖啡", "料理"].contains(where: { value.contains($0) }) {
            return "fork.knife"
        }
        if ["旅行", "目的地", "路线", "景点", "散步"].contains(where: { value.contains($0) }) {
            return "map"
        }
        if ["游戏", "桌游"].contains(where: { value.contains($0) }) {
            return "gamecontroller"
        }
        if ["展览", "博物馆", "美术馆"].contains(where: { value.contains($0) }) {
            return "building.columns"
        }
        if ["演出", "演唱会", "音乐节", "戏剧", "活动"].contains(where: { value.contains($0) }) {
            return "ticket"
        }
        if ["运动", "户外", "健身"].contains(where: { value.contains($0) }) {
            return "figure.run"
        }
        if ["应用", "软件", "工具"].contains(where: { value.contains($0) }) {
            return "apps.iphone"
        }
        return "sparkles"
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
                        Text("写下你想推荐给 \(partnerName) 的东西…")
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
