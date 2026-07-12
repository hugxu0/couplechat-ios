import SwiftUI

struct PetView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PetViewModel()
    @State private var showAIChat = false
    @State private var showRename = false
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                content(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPageBackground())
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showAIChat) {
                ChatView(channel: .ai)
            }
            .sheet(isPresented: $showRename) {
                renameSheet
            }
            .task(id: store.session?.username) {
                guard let session = store.session else { return }
                await viewModel.load(token: session.token, username: session.username)
            }
            .task(id: "pet-poll.\(store.session?.username ?? "none")") {
                await liveRefreshLoop()
            }
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
        }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if let pet = viewModel.snapshot?.pet, let session = store.session {
            petLayout(pet: pet, session: session, size: size)
        } else if viewModel.isLoading {
            ProgressView("正在打开窗边小窝…")
                .foregroundStyle(DS.Palette.textSecondary)
        } else {
            unavailableState
        }
    }

    private func petLayout(pet: CouplePetState, session: Session, size: CGSize) -> some View {
        let inset = DS.Spacing.page
        let availableWidth = max(0, size.width - inset * 2)
        let metrics = PetLayoutMetrics.resolve(
            width: availableWidth,
            height: size.height,
            hasRegularHorizontalSizeClass: horizontalSizeClass == .regular)

        return Group {
            if metrics.mode == .split {
                splitLayout(pet: pet, session: session, metrics: metrics)
            } else {
                stackedLayout(pet: pet, session: session, metrics: metrics)
            }
        }
        .frame(width: metrics.totalContentWidth)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private func splitLayout(
        pet: CouplePetState,
        session: Session,
        metrics: PetLayoutMetrics
    ) -> some View {
        HStack(spacing: 14) {
            scene(pet: pet, session: session)
                .frame(width: metrics.sceneWidth)
            panel(pet: pet, session: session, showsDrawerHandle: false)
                .frame(width: metrics.panelWidth)
        }
    }

    private func stackedLayout(
        pet: CouplePetState,
        session: Session,
        metrics: PetLayoutMetrics
    ) -> some View {
        VStack(spacing: -22) {
            scene(pet: pet, session: session)
                .frame(height: metrics.stackedSceneHeight)
            panel(pet: pet, session: session, showsDrawerHandle: true)
                .frame(maxHeight: .infinity)
        }
    }

    private func scene(pet: CouplePetState, session: Session) -> some View {
        PetSceneView(
            pet: pet,
            isBusy: viewModel.isMutating,
            feedback: viewModel.feedback,
            onRename: { showRename = true },
            onChat: { showAIChat = true },
            onInteraction: { kind in
                Haptics.light()
                Task {
                    await viewModel.interact(
                        kind: kind, token: session.token, username: session.username)
                }
            })
    }

    private func panel(
        pet: CouplePetState,
        session: Session,
        showsDrawerHandle: Bool
    ) -> some View {
        PetContentPanel(
            pet: pet,
            currentUsername: session.username,
            isBusy: viewModel.isMutating,
            errorMessage: viewModel.errorMessage,
            usingCachedSnapshot: viewModel.usingCachedSnapshot,
            showsDrawerHandle: showsDrawerHandle,
            onRespond: { text in
                await viewModel.respond(
                    text: text, token: session.token, username: session.username)
            },
            onPlaceItems: { ids in
                Task {
                    await viewModel.updateScene(
                        placedItemIds: ids,
                        token: session.token,
                        username: session.username)
                }
            },
            onRefresh: {
                await refreshIfPossible()
            })
    }

    private var unavailableState: some View {
        VStack(spacing: 16) {
            AppEmptyState(
                "小窝暂时没有打开",
                systemImage: "pawprint",
                detail: viewModel.errorMessage ?? "确认登录与网络状态后重试")
            if let session = store.session {
                Button("重新载入") {
                    Task {
                        await viewModel.load(
                            token: session.token, username: session.username, force: true)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Spacing.page)
    }

    private func refreshIfPossible() async {
        guard let session = store.session else { return }
        await viewModel.load(
            token: session.token, username: session.username, force: true)
    }

    private func liveRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            if isVisible, scenePhase == .active { await refreshIfPossible() }
        }
    }

    @ViewBuilder
    private var renameSheet: some View {
        if let pet = viewModel.snapshot?.pet, let session = store.session {
            PetRenameSheet(currentName: pet.name) { name in
                await viewModel.rename(
                    name, token: session.token, username: session.username)
            }
        }
    }
}
