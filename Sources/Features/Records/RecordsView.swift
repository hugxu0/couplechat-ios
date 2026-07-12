import SwiftUI

struct RecordsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @StateObject private var model = MomentsViewModel()
    @State private var daily: DailyContent?
    @State private var showingCreateAlbum = false
    @State private var showingDateEditor = false

    var body: some View {
        NavigationSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                    RootPageHeader("时光", subtitle: "把聊天里的日常，慢慢收成我们") {
                        Button {
                            Haptics.medium()
                            showingCreateAlbum = true
                        } label: {
                            Image(systemName: "plus")
                                .font(DS.Typo.button)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("新建共同相册")
                    }
                    .padding(.horizontal, -DS.Spacing.page)

                    onThisDaySection
                    albumSection
                    coupleOverview
                    ChatStatsCard()
                    dailyCard
                    errorSection
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await reload(force: true) }
            .task { await reload() }
            .onReceive(NotificationCenter.default.publisher(for: MomentsViewModel.albumsChanged)) { _ in
                Task { await reload(force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
                guard note.persistentSyncIncludes(["album", "album_item", "media_note", "media_asset"]) else {
                    return
                }
                Task { await reload(force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: MomentsViewModel.albumsChanged)) { _ in
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
        } detail: {
            ContentUnavailableView(
                "选择一册时光",
                systemImage: "photo.on.rectangle.angled",
                description: Text("相册会在这里以更宽的画布展开"))
                .background(AppPageBackground())
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
                            AlbumDetailView(album: album)
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
            AppSectionHeader(title: "我们的时间")
            Button {
                Haptics.light()
                showingDateEditor = true
            } label: {
                HStack(spacing: DS.Spacing.card) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("我们在一起")
                            .font(DS.Typo.secondary.weight(.medium))
                            .foregroundStyle(.white.opacity(0.78))
                        Text(togetherLabel)
                            .font(DS.Typo.displayNumber)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(DS.Spacing.card)
                .frame(maxWidth: .infinity, minHeight: 104)
                .background(theme.accent.gradient)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("我们在一起\(togetherLabel)，轻点编辑日期")

            if !store.anniversaries.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: DS.Spacing.gap) {
                        ForEach(store.anniversaries) { entry in
                            anniversaryChip(entry)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func anniversaryChip(_ entry: AnniversaryEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.icon).foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(DS.Typo.caption.weight(.semibold)).lineLimit(1)
                Text(entry.days.map { "\($0)\(entry.direction == .up ? " 天" : " 天后")" } ?? "未设置")
                    .font(DS.Typo.secondary.monospacedDigit().weight(.semibold))
            }
        }
        .foregroundStyle(DS.Palette.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .dsCard(radius: DS.Radius.control)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var dailyCard: some View {
        if let diary = daily?.diary {
            AppCard {
                VStack(alignment: .leading, spacing: DS.Spacing.compact) {
                    Label("大橘日记", systemImage: "pawprint.fill")
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.orange)
                    Text(diary.text)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineSpacing(4)
                }
            }
        }
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

    private func reload(force: Bool = false) async {
        guard let token = store.session?.token else { return }
        async let moments: Void = model.load(token: token, force: force)
        async let dailyResult = store.dailyContent.fetch(token: token)
        let (_, fetchedDaily) = await (moments, dailyResult)
        if let fetchedDaily { daily = fetchedDaily }
    }

    private func loadMore(_ album: MomentAlbum) async {
        guard let token = store.session?.token else { return }
        await model.loadMoreIfNeeded(album: album, token: token)
    }
}
