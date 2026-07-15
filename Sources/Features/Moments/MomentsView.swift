import SwiftUI

struct MomentsView: View {
    private enum RecommendationSheet: Identifiable {
        case composer
        case history
        case received(RecommendationItem)

        var id: String {
            switch self {
            case .composer: return "composer"
            case .history: return "history"
            case .received(let item): return "received-\(item.id)"
            }
        }
    }

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var model = MomentsViewModel()
    @StateObject private var recommendationModel = RecommendationViewModel()
    @StateObject private var badges = AppBadgeState.shared
    @State private var showingCreateAlbum = false
    @State private var showingDateEditor = false
    @State private var recommendationSheet: RecommendationSheet?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                    coupleOverview
                    onThisDaySection
                    ChatStatsCard()
                    TodayRecommendationCard(
                        snapshot: recommendationModel.today,
                        loading: recommendationModel.loading,
                        refreshing: recommendationModel.refreshing,
                        onRefresh: { Task { await refreshRecommendation() } },
                        onHistory: { recommendationSheet = .history },
                        onGift: { recommendationSheet = .composer })
                    albumSection
                    errorSection
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await reload() }
            .onAppear {
                Task { await loadRecommendations(presentUnread: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: MomentsViewModel.albumsChanged)) { _ in
                Task { await reload(force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
                if note.persistentSyncIncludes(["album", "album_item", "media_note", "media_asset"]) {
                    Task { await reload(force: true) }
                }
                if note.persistentSyncIncludes(["recommendation", "recommendation_state"]) {
                    Task {
                        await loadRecommendations(presentUnread: false)
                        if let token = store.session?.token {
                            await badges.refreshRecommendations(token: token)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCreateAlbum) {
                AlbumCreateSheet { title, note in
                    guard let token = store.session?.token else { return false }
                    return await model.createAlbum(title: title, note: note, token: token)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingDateEditor) {
                DateEditorSheet().presentationDetents([.medium, .large])
            }
            .sheet(item: $recommendationSheet) { sheet in
                recommendationSheetContent(sheet)
            }
        }
    }

    @ViewBuilder
    private func recommendationSheetContent(_ sheet: RecommendationSheet) -> some View {
        switch sheet {
        case .composer:
            RecommendationComposerSheet(partnerName: partnerDisplayName) { content in
                await sendRecommendation(content)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .history:
            if let token = store.session?.token {
                RecommendationHistoryView(token: token)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        case .received(let item):
            ReceivedRecommendationSheet(item: item) {
                Task { await acceptRecommendation(item) }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var onThisDaySection: some View {
        if model.loading && model.onThisDay.isEmpty {
            AppCard {
                HStack(spacing: DS.Spacing.gap) {
                    ProgressView()
                    Text("正在翻找过去的今天…")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        } else if let moment = model.onThisDay.first {
            VStack(alignment: .leading, spacing: DS.Spacing.gap) {
                AppSectionHeader(title: "今天的回声", subtitle: "同一天发生过的共同片段")
                OnThisDayCard(moment: moment)
            }
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            HStack(alignment: .center, spacing: DS.Spacing.gap) {
                AppSectionHeader(title: "共同相册", subtitle: "不同相簿，收好不同阶段的我们")
                Spacer(minLength: 8)
                Button {
                    showingCreateAlbum = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(DS.Palette.accent.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建共同相册")
            }
            if model.loading && model.albums.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if model.albums.isEmpty {
                VStack(spacing: DS.Spacing.gap) {
                    AppEmptyState(
                        "还没有共同相册",
                        systemImage: "photo.stack",
                        detail: "先建一册，再把聊天里的照片和视频收进来。")
                    Button("新建第一本相册", systemImage: "plus") { showingCreateAlbum = true }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                }
                .padding(.vertical, DS.Spacing.gap)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DS.Spacing.gap) {
                    ForEach(model.albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album).appSubpageChrome()
                        } label: {
                            MomentAlbumCard(album: album)
                        }
                        .buttonStyle(PressableStyle())
                        .frame(width: 260)
                        .task { await loadMore(album) }
                    }
                    Button {
                        showingCreateAlbum = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 34))
                            Text("再建一本").font(DS.Typo.button)
                        }
                        .foregroundStyle(DS.Palette.accent)
                        .frame(width: 150, height: 220)
                        .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("新建共同相册")
                    }
                }
                if model.loadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
        }
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.card)
    }

    private var coupleOverview: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            Button {
                Haptics.light()
                showingDateEditor = true
            } label: {
                VStack(spacing: 7) {
                    Text("我们在一起的第")
                        .font(DS.Typo.secondary.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text(togetherNumber)
                        .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(togetherNumber == "等待设置" ? "" : "天")
                        .font(DS.Typo.secondary.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("有你在侧，平凡也晴朗。")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(DS.Spacing.card)
                .frame(maxWidth: .infinity, minHeight: 220)
                .background {
                    ZStack {
                        LinearGradient(
                            colors: [theme.accent.color, DS.Palette.purple.opacity(0.86)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                        Circle()
                            .fill(.white.opacity(0.10))
                            .frame(width: 170, height: 170)
                            .offset(x: 142, y: -82)
                        Circle()
                            .stroke(.white.opacity(0.13), lineWidth: 18)
                            .frame(width: 112, height: 112)
                            .offset(x: -150, y: 92)
                        Image(systemName: "heart.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white.opacity(0.12))
                            .rotationEffect(.degrees(-14))
                            .offset(x: 118, y: 70)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .shadow(color: theme.accent.color.opacity(0.18), radius: 18, y: 9)
                }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("我们在一起\(togetherLabel)，轻点编辑日期")

            if !store.anniversaries.isEmpty {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.gap), count: 2),
                    spacing: DS.Spacing.gap
                ) {
                    ForEach(store.anniversaries) { entry in
                        anniversaryChip(entry)
                    }
                }
            }
        }
    }

    private func anniversaryChip(_ entry: AnniversaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: entry.icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(theme.accent.color)
            Text(entry.title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(2)
            Text(entry.days.map { "\($0)\(entry.direction == .up ? " 天" : " 天后")" } ?? "未设置")
                .font(DS.Typo.cardTitle.monospacedDigit())
                .foregroundStyle(DS.Palette.textPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .dsCard(radius: DS.Radius.card)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.errorMessage {
            StatusBanner(text: message, kind: .error)
        }
        if let message = recommendationModel.errorMessage {
            StatusBanner(text: message, kind: .error)
        }
    }

    private var togetherLabel: String {
        CoupleDates.daysSince(store.coupleDates.together).map { "\($0) 天" } ?? "等待设置"
    }

    private var togetherNumber: String {
        CoupleDates.daysSince(store.coupleDates.together).map(String.init) ?? "等待设置"
    }

    private func reload(force: Bool = false) async {
        guard let token = store.session?.token else { return }
        await model.load(token: token, force: force)
    }

    private var partnerDisplayName: String {
        store.partner?.name ?? "TA"
    }

    private func loadRecommendations(presentUnread: Bool) async {
        guard let token = store.session?.token else { return }
        let unread = await recommendationModel.load(token: token)
        guard presentUnread, recommendationSheet == nil, let unread else { return }
        recommendationSheet = .received(unread)
    }

    private func refreshRecommendation() async {
        guard let token = store.session?.token else { return }
        await recommendationModel.refresh(token: token)
    }

    private func sendRecommendation(_ content: String) async -> Bool {
        guard let token = store.session?.token else { return false }
        return await recommendationModel.send(content, token: token)
    }

    private func acceptRecommendation(_ item: RecommendationItem) async {
        guard let token = store.session?.token else { return }
        await recommendationModel.markRead(item, token: token)
        await badges.refreshRecommendations(token: token)
    }

    private func loadMore(_ album: MomentAlbum) async {
        guard let token = store.session?.token else { return }
        await model.loadMoreIfNeeded(album: album, token: token)
    }
}
