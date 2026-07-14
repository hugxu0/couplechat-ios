import SwiftUI

struct DajuView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = DajuViewModel()
    @State private var showAIChat = false
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            Group {
                if let pet = viewModel.snapshot?.pet, let session = store.session {
                    petHome(pet: pet, session: session)
                } else if viewModel.isLoading {
                    ProgressView("正在叫醒大橘…")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    unavailableState
                }
            }
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showAIChat) {
                ChatView(channel: .ai).appSubpageChrome()
            }
            .task(id: store.session?.username) {
                guard let session = store.session else { return }
                await viewModel.load(token: session.token, username: session.username)
            }
            .task(id: "pet-poll.\(store.session?.username ?? "none")") { await liveRefreshLoop() }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshIfPossible() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
                guard note.persistentSyncIncludes(["pet"]) else { return }
                Task { await refreshIfPossible() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openDajuChatDeepLink)) { _ in
                showAIChat = true
            }
        }
    }

    private func petHome(pet: CouplePetState, session: Session) -> some View {
        ScrollView {
            LazyVStack(spacing: DS.Spacing.section) {
                DajuSceneView(
                    pet: pet,
                    isBusy: viewModel.isMutating,
                    feedback: viewModel.feedback,
                    onChat: { showAIChat = true },
                    onInteraction: { kind in
                        Haptics.light()
                        Task {
                            await viewModel.interact(
                                kind: kind, token: session.token, username: session.username)
                        }
                    })
                if viewModel.usingCachedSnapshot {
                    StatusBanner(text: "网络暂不可用，正在展示上次同步的大橘状态", kind: .info)
                } else if let message = viewModel.errorMessage {
                    StatusBanner(text: message, kind: .warning)
                }
                DajuDiaryCard()
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, DS.Spacing.page)
            .padding(.top, 8)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var unavailableState: some View {
        VStack(spacing: 16) {
            AppEmptyState(
                "大橘还没醒",
                systemImage: "pawprint",
                detail: viewModel.errorMessage ?? "确认登录与网络状态后重试")
            if let session = store.session {
                Button("重新载入") {
                    Task { await viewModel.load(token: session.token, username: session.username, force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Spacing.page)
    }

    private func refreshIfPossible() async {
        guard let session = store.session else { return }
        await viewModel.load(token: session.token, username: session.username, force: true)
    }

    private func liveRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            if isVisible, scenePhase == .active { await refreshIfPossible() }
        }
    }
}

private struct DajuDiaryCard: View {
    @EnvironmentObject private var store: ChatStore
    @State private var daily: DailyContent?

    private var entries: [DiaryEntry] {
        Array((daily?.diaries ?? []).prefix(30))
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: DS.Spacing.compact) {
                HStack {
                    Label("大橘日记", systemImage: "pawprint.fill")
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.orange)
                    Spacer()
                    Text(entries.isEmpty ? "最近 30 天" : "最近 \(entries.count) 篇")
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }

                if daily?.backfilling == true {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("大橘仍在整理最近 30 天，日记会陆续补齐")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                if entries.isEmpty {
                    ContentUnavailableView(
                        "还没有日记",
                        systemImage: "book.closed",
                        description: Text("正在整理最近 30 天有聊天的日子"))
                        .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: DS.Spacing.compact) {
                            ForEach(entries, id: \.date) { diary in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(diary.date)
                                        .font(DS.Typo.caption.weight(.semibold))
                                        .foregroundStyle(DS.Palette.orange)
                                    diaryText(diary.text)
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
                    .frame(minHeight: 390, maxHeight: 560)
                    .scrollIndicators(.hidden)
                }
            }
        }
        .task(id: store.session?.username) {
            await loadAndFollowBackfill()
        }
    }

    private func loadAndFollowBackfill() async {
        guard let token = store.session?.token else { return }
        daily = await store.dailyContent.fetch(token: token)
        while !Task.isCancelled && (daily == nil || daily?.backfilling == true) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            if let fetched = await store.dailyContent.fetch(token: token) { daily = fetched }
        }
    }

    private func diaryText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(markdown: markdown) {
            return Text(attributed)
        }
        return Text(markdown)
    }
}
