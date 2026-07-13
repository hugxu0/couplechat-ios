import SwiftUI

struct MomentsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var model = MomentsViewModel()
    @State private var daily: DailyContent?
    @State private var showingCreateAlbum = false
    @State private var showingDateEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                    coupleOverview
                    onThisDaySection
                    ChatStatsCard()
                    dailyCard
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
            .task(id: "diary-history.\(store.session?.username ?? "none")") {
                await loadDiaryHistoryUntilAvailable()
            }
            .onReceive(NotificationCenter.default.publisher(for: MomentsViewModel.albumsChanged)) { _ in
                Task { await reload(force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
                guard note.persistentSyncIncludes(["album", "album_item", "media_note", "media_asset"]) else {
                    return
                }
                Task { await reload(force: true) }
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
            AppSectionHeader(title: "共同相册", subtitle: "长按聊天媒体即可收藏进来")
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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: DS.Spacing.gap)],
                    spacing: DS.Spacing.gap
                ) {
                    ForEach(model.albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album).appSubpageChrome()
                        } label: {
                            MomentAlbumCard(album: album)
                        }
                        .buttonStyle(PressableStyle())
                        .task { await loadMore(album) }
                    }
                }
                if model.loadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
        }
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

    private var dailyCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: DS.Spacing.compact) {
                HStack {
                    Label("大橘日记", systemImage: "pawprint.fill")
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.orange)
                    Spacer()
                    Text(diaryEntries.isEmpty ? "最近 30 天" : "最近 \(diaryEntries.count) 篇")
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }

                if diaryEntries.isEmpty {
                    ContentUnavailableView(
                        "还没有日记",
                        systemImage: "book.closed",
                        description: Text("正在整理最近 30 天有聊天的日子"))
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: DS.Spacing.compact) {
                            ForEach(diaryEntries, id: \.date) { diary in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(diary.date)
                                        .font(DS.Typo.caption.weight(.semibold))
                                        .foregroundStyle(DS.Palette.orange)
                                    Text(diary.text)
                                        .font(DS.Typo.body)
                                        .foregroundStyle(DS.Palette.textPrimary)
                                        .lineSpacing(5)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(
                                    DS.Palette.innerSurface,
                                    in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                                        .stroke(DS.Palette.orange.opacity(0.12), lineWidth: 0.8)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 320, maxHeight: 460)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private var diaryEntries: [DiaryEntry] {
        Array((daily?.diaries ?? []).prefix(30))
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.errorMessage {
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
        async let moments: Void = model.load(token: token, force: force)
        async let dailyResult = store.dailyContent.fetch(token: token)
        let (_, fetchedDaily) = await (moments, dailyResult)
        if let fetchedDaily { daily = fetchedDaily }
    }

    private func loadDiaryHistoryUntilAvailable() async {
        guard let token = store.session?.token else { return }
        for _ in 0..<4 {
            if !(daily?.diaries.isEmpty ?? true) { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            if let fetched = await store.dailyContent.fetch(token: token) { daily = fetched }
        }
    }

    private func loadMore(_ album: MomentAlbum) async {
        guard let token = store.session?.token else { return }
        await model.loadMoreIfNeeded(album: album, token: token)
    }
}
