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
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.top, 8)
            .padding(.bottom, 96)
            .appReadableWidth(820)
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
