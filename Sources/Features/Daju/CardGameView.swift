import SwiftUI

// 卡牌页把抽卡、效果、卡库和轮询放在同一页面状态里，便于首版联调。
// 其余卡面组件已拆到独立文件；这里仅局部放宽结构检查。
// swiftlint:disable type_body_length function_body_length
struct CardGameView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = CardGameViewModel()
    @State private var selectedItem: CardGameInventoryItem?
    @State private var showCollection = false
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

                    // 无快照时 unavailableState 已展示错误，这里只兜局部失败，避免同一句话出现两遍。
                    if let error = viewModel.errorMessage, viewModel.snapshot != nil {
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.light()
                    showCollection = true
                } label: {
                    Label("图鉴", systemImage: "book.closed.fill")
                }
                .disabled(viewModel.snapshot == nil)
            }
        }
        .task(id: store.session?.username) {
            await pollingLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refresh(force: true) }
        }
        // sheet(item:) 保证内容与所选卡一起出现，不会再弹出一张空白页。
        .sheet(item: $selectedItem) { item in
            if let snapshot = viewModel.snapshot,
               let definition = snapshot.definition(for: item) {
                CardGameSelectionSheet(
                    item: item,
                    definition: definition,
                    effects: snapshot.activeEffects,
                    partnerInventory: snapshot.partnerInventory,
                    catalog: snapshot.catalog,
                    currentUsername: store.session?.username ?? "",
                    onUse: { effectID, source in
                        selectedItem = nil
                        Task { await use(item: item, effectID: effectID, source: source) }
                    })
                .presentationSizing(.form)
            }
        }
        .sheet(isPresented: $showCollection) {
            if let snapshot = viewModel.snapshot {
                CardGameCollectionView(snapshot: snapshot)
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
                    Text("图鉴 \(collectedCount(snapshot)) / \(snapshot.catalog.count)")
                        .font(DS.Typo.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.78))
                }
                Text("抽到就留下，想用时再出牌")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("每天每人 3 次机会，前两次都没中时最后一次必中。使用后卡片消耗，效果会留在这里等对方看到。")
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
                // 与下方进度条同一语义（已用几次），否则"0/3"配三条满格看着自相矛盾。
                Text("\(snapshot.drawsUsed) / 3")
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
                        Image(systemName: snapshot.drawsRemaining == 0 ? "moon.zzz.fill" : "shuffle")
                    }
                    Text(buttonTitle(snapshot: snapshot))
                        .font(DS.Typo.button)
                    Spacer()
                    if snapshot.drawsRemaining > 0 {
                        Text("约 1/3 命中 · 末抽保底")
                            .font(DS.Typo.micro)
                            .foregroundStyle(.white.opacity(0.75))
                    }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 11)], spacing: 13) {
                    ForEach(snapshot.inventory) { item in
                        if let definition = snapshot.definition(for: item) {
                            Button {
                                Haptics.light()
                                beginUse(item)
                            } label: {
                                CardFaceView(definition: definition, quantity: item.quantity, compact: true)
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(viewModel.isMutating)
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

    private func buttonTitle(snapshot: CardGameSnapshot) -> String {
        if viewModel.isMutating { return "正在洗牌…" }
        if snapshot.drawsRemaining == 0 { return "今天抽完了，明天 00:00 再来" }
        return "抽一张"
    }

    private func collectedCount(_ snapshot: CardGameSnapshot) -> Int {
        let owned = Set(snapshot.inventory.map { "\($0.cardKey)|\($0.rarity.rawValue)" })
        return snapshot.catalog.filter { owned.contains("\($0.key)|\($0.rarity.rawValue)") }.count
    }

    /// 所有卡都先进详情弹窗看大卡面再确认使用；不再有"点一下直接消耗"的路径。
    private func beginUse(_ item: CardGameInventoryItem) {
        selectedItem = item
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
            drawMessage = "这次没有抽中。今天前两次都没中的话，最后一次必中。"
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
            if Task.isCancelled { return }
            // 会话短暂缺失只跳过这一轮；退出循环后 .task(id:) 不会重启，轮询会永久停掉。
            guard let current = store.session else { continue }
            await viewModel.load(token: current.token, username: current.username, force: true)
        }
    }
}
// swiftlint:enable type_body_length function_body_length
