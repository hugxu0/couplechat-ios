import SwiftUI

// 卡牌页把抽卡、效果、卡库和轮询放在同一页面状态里，便于首版联调。
// 其余卡面组件已拆到独立文件；这里仅局部放宽结构检查。
// swiftlint:disable type_body_length function_body_length
struct CardGameView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CardGameViewModel()
    @State private var selectedItem: CardGameInventoryItem?
    @State private var showSelection = false
    @State private var revealCard: CardGameDefinition?
    @State private var showReveal = false
    @State private var drawMessage: String?

    var body: some View {
        ZStack {
            AppPageBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                    if let snapshot = viewModel.snapshot {
                        hero(snapshot: snapshot)
                        drawPanel(snapshot: snapshot)

                        if !snapshot.activeEffects.isEmpty {
                            activeEffects(snapshot: snapshot)
                        }

                        inventory(snapshot: snapshot)
                        recentEffects(snapshot: snapshot)
                    } else if viewModel.isLoading {
                        loadingState
                    } else {
                        unavailableState
                    }

                    if let error = viewModel.errorMessage {
                        StatusBanner(text: error, kind: .warning)
                    }
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, 8)
                .padding(.bottom, 44)
                .appReadableWidth(880)
            }
            .scrollIndicators(.hidden)
            .refreshable { await refresh(force: true) }

            if showReveal, let revealCard {
                CardRevealOverlay(card: revealCard) {
                    showReveal = false
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .zIndex(3)
            }
        }
        .navigationTitle("情侣卡牌")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.session?.username) {
            await pollingLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh(force: true) }
        }
        .sheet(isPresented: $showSelection) {
            if let selectedItem,
               let snapshot = viewModel.snapshot,
               let definition = snapshot.definition(for: selectedItem) {
                CardGameSelectionSheet(
                    item: selectedItem,
                    definition: definition,
                    effects: snapshot.activeEffects,
                    partnerInventory: snapshot.partnerInventory,
                    catalog: snapshot.catalog,
                    currentUsername: store.session?.username ?? "",
                    onUse: { effectID, source in
                        showSelection = false
                        Task { await use(item: selectedItem, effectID: effectID, source: source) }
                    })
                .presentationSizing(.form)
            }
        }
        .alert("这次没有抽中", isPresented: Binding(
            get: { drawMessage != nil },
            set: { if !$0 { drawMessage = nil } })) {
            Button("好") { drawMessage = nil }
        } message: {
            Text(drawMessage ?? "再来试试，今天还剩下机会。")
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在洗牌…")
                .font(DS.Typo.cardTitle)
            Text("卡库只属于你们两个人")
                .font(DS.Typo.secondary)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var unavailableState: some View {
        AppEmptyState(
            "卡牌暂时打不开",
            systemImage: "rectangle.stack.badge.exclamationmark",
            detail: viewModel.errorMessage ?? "确认登录和情侣关系后再试试")
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func hero(snapshot: CardGameSnapshot) -> some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [DS.Palette.purple.opacity(0.92), DS.Palette.blue.opacity(0.78), DS.Palette.pink.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 118, weight: .black))
                .foregroundStyle(.white.opacity(0.11))
                .rotationEffect(.degrees(-14))
                .offset(x: 12, y: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Label("两个人的卡库", systemImage: "heart.fill")
                        .font(DS.Typo.sectionLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.16), in: Capsule())
                    Spacer()
                    Text("\(snapshot.inventory.count) 种")
                        .font(DS.Typo.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                }
                Text("抽到就留下，想用时再出牌")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("每天每人 3 次机会，每次约三分之一概率抽中。使用后卡片消耗，效果会留在这里等对方看到。")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
            }
            .foregroundStyle(.white)
            .padding(DS.Spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        }
        .shadow(color: DS.Palette.purple.opacity(0.18), radius: 18, y: 8)
    }

    private func drawPanel(snapshot: CardGameSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日抽卡")
                        .font(DS.Typo.cardTitle)
                    Text("北京时间每天 00:00 重置")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Text("\(snapshot.drawsRemaining) / 3")
                    .font(DS.Typo.displayNumber.monospacedDigit())
                    .foregroundStyle(snapshot.drawsRemaining > 0 ? DS.Palette.purple : DS.Palette.textTertiary)
            }

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index < snapshot.drawsUsed ? DS.Palette.purple : DS.Palette.textTertiary.opacity(0.16))
                        .frame(height: 9)
                }
            }

            Button {
                Haptics.medium()
                Task { await draw() }
            } label: {
                HStack(spacing: 9) {
                    if viewModel.isMutating {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "shuffle")
                    }
                    Text(viewModel.isMutating ? "正在洗牌…" : "抽一张")
                        .font(DS.Typo.button)
                    Spacer()
                    Text("命中率约 1 / 3")
                        .font(DS.Typo.micro)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(
                    LinearGradient(
                        colors: [DS.Palette.purple, DS.Palette.blue],
                        startPoint: .leading,
                        endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(snapshot.drawsRemaining == 0 || viewModel.isMutating)
            .opacity(snapshot.drawsRemaining == 0 ? 0.55 : 1)
        }
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.panel)
    }

    private func activeEffects(snapshot: CardGameSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader(title: "正在生效", subtitle: "多张卡可以同时倒计时")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 9) {
                    ForEach(snapshot.activeEffects) { effect in
                        CardGameEffectRow(
                            effect: effect,
                            now: context.date,
                            currentUsername: store.session?.username ?? "")
                    }
                }
            }
        }
    }

    private func inventory(snapshot: CardGameSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader(title: "我的卡库", subtitle: "保存的卡片不会自动消失，使用一次消耗一张")
            if snapshot.inventory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.title2)
                        .foregroundStyle(DS.Palette.textTertiary)
                    Text("还没有存下卡片")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
                .dsCard(radius: DS.Radius.panel, elevated: false)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 11)], spacing: 11) {
                    ForEach(snapshot.inventory) { item in
                        if let definition = snapshot.definition(for: item) {
                            CardGameCardTile(
                                item: item,
                                definition: definition,
                                isBusy: viewModel.isMutating,
                                onUse: { beginUse(item) })
                        }
                    }
                }
            }
        }
    }

    private func recentEffects(snapshot: CardGameSnapshot) -> some View {
        let history = snapshot.recentEffects.filter {
            $0.expiresAt == nil || ($0.status != "active" && $0.status != "pending")
        }.prefix(12)
        return VStack(alignment: .leading, spacing: 11) {
            sectionHeader(title: "出牌记录", subtitle: "进入页面就能看到对方刚刚使用的效果")
            if history.isEmpty {
                Text("还没有出牌记录")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.card)
                    .dsCard(radius: DS.Radius.panel, elevated: false)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history)) { effect in
                        CardGameHistoryRow(effect: effect, currentUsername: store.session?.username ?? "")
                        if effect.id != history.last?.id {
                            Divider().padding(.leading, 45)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .dsCard(radius: DS.Radius.panel, elevated: false)
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(DS.Typo.cardTitle)
                .foregroundStyle(DS.Palette.textPrimary)
            Text(subtitle)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func beginUse(_ item: CardGameInventoryItem) {
        guard let snapshot = viewModel.snapshot,
              let definition = snapshot.definition(for: item) else { return }
        if definition.modifier == nil {
            Task { await use(item: item) }
        } else {
            selectedItem = item
            showSelection = true
        }
    }

    private func use(
        item: CardGameInventoryItem,
        effectID: String? = nil,
        source: CardGameInventoryItem? = nil
    ) async {
        guard let session = store.session else { return }
        _ = await viewModel.use(
            token: session.token,
            username: session.username,
            item: item,
            effectID: effectID,
            source: source)
    }

    private func draw() async {
        guard let session = store.session else { return }
        guard let result = await viewModel.draw(token: session.token, username: session.username) else { return }
        if result.success, let card = result.card {
            revealCard = card
            withAnimation(DS.Anim.motion(DS.Anim.spring)) { showReveal = true }
        } else {
            drawMessage = "这次没有抽中卡片，但抽卡次数已经记录。"
        }
    }

    private func refresh(force: Bool) async {
        guard let session = store.session else { return }
        await viewModel.load(token: session.token, username: session.username, force: force)
    }

    private func pollingLoop() async {
        guard let session = store.session else { return }
        await viewModel.load(token: session.token, username: session.username, force: true)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, scenePhase == .active,
                  let current = store.session else { return }
            await viewModel.load(token: current.token, username: current.username, force: true)
        }
    }
}
// swiftlint:enable type_body_length function_body_length
