import SwiftUI

struct DajuDiaryEntryCard: View {
    let token: String
    let onOpen: () -> Void

    @State private var latestDiary: DajuDiary?
    @State private var loading = true
    @State private var loadFailed = false
    private let repository = DajuDiaryRepository()

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            ZStack(alignment: .topTrailing) {
                entryBackground
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 82, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.10))
                    .rotationEffect(.degrees(-16))
                    .offset(x: 14, y: -12)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label("大橘日记", systemImage: "book.closed.fill")
                            .font(DS.Typo.cardTitle)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    if loading {
                        HStack(spacing: 9) {
                            ProgressView().tint(.white)
                            Text("正在翻找最近的爪印…")
                                .font(DS.Typo.secondary)
                        }
                        .frame(minHeight: 54, alignment: .leading)
                    } else if let latestDiary {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(latestDiary.monthDayText)
                                .font(DS.Typo.caption.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.72))
                            Text(latestDiary.title)
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .lineLimit(2)
                            Text(latestDiary.previewText)
                                .font(DS.Typo.secondary)
                                .foregroundStyle(Color.white.opacity(0.80))
                                .lineLimit(2)
                                .lineSpacing(2)
                        }
                    } else if loadFailed {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("日记本暂时合上了")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                            Text("点开后可以重新加载，不会影响大橘的其他状态。")
                                .font(DS.Typo.secondary)
                                .foregroundStyle(Color.white.opacity(0.80))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("今天的墨迹还在晾干")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                            Text("有共同聊天的日子，大橘会替你们留下一页。")
                                .font(DS.Typo.secondary)
                                .foregroundStyle(Color.white.opacity(0.80))
                        }
                    }

                    Label("共同聊天里的小事，只写给你们两个人", systemImage: "heart.fill")
                        .font(DS.Typo.caption)
                        .foregroundStyle(Color.white.opacity(0.70))
                }
                .foregroundStyle(.white)
                .padding(DS.Spacing.card)
                .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
            }
            .shadow(color: DS.Palette.orange.opacity(0.16), radius: 16, y: 8)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("打开大橘日记")
        .task(id: token) { await loadLatest() }
        .onReceive(NotificationCenter.default.publisher(for: DajuDiaryRepository.changedNotification)) { _ in
            Task { await loadLatest() }
        }
    }

    private var entryBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.48, blue: 0.22),
                Color(red: 0.93, green: 0.35, blue: 0.48),
                Color(red: 0.58, green: 0.38, blue: 0.86),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private func loadLatest() async {
        loading = true
        defer { loading = false }
        do {
            let diaries = try await repository.list(token: token, limit: 1)
            latestDiary = diaries.first
            loadFailed = false
        } catch {
            latestDiary = nil
            loadFailed = true
        }
    }
}

struct DajuDiaryView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var diaries: [DajuDiary] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var noticeText: String?
    @State private var noticeKind: StatusBanner.Kind = .info
    @State private var ensuring = false
    private let repository = DajuDiaryRepository()

    var body: some View {
        ZStack {
            AppPageBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                    diaryHero
                    if let noticeText {
                        StatusBanner(text: noticeText, kind: noticeKind)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    diaryContent
                    privacyNote
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.top, DS.Spacing.compact)
                .padding(.bottom, 44)
                .appReadableWidth(760)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
        }
        .navigationTitle("大橘日记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ensureToolbarItem }
        .task { await reload() }
    }

    private var diaryHero: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [DS.Palette.orange.opacity(0.16), DS.Palette.pink.opacity(0.09), DS.Palette.innerSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Image(systemName: "book.pages.fill")
                .font(.system(size: 104, weight: .light))
                .foregroundStyle(DS.Palette.orange.opacity(0.08))
                .offset(x: 18, y: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 13) {
                Label("大橘的共同记忆簿", systemImage: "pawprint.fill")
                    .font(DS.Typo.sectionLabel)
                    .foregroundStyle(DS.Palette.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DS.Palette.orange.opacity(0.11), in: Capsule())

                Text("把普通的一天，\n收进一枚温柔的爪印")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("大橘会在北京时间 06:00 之后，回看前一个作息日的共同聊天，写下值得记住的小事。")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !diaries.isEmpty {
                    Label("已经收藏 \(diaries.count) 个共同日子", systemImage: "books.vertical.fill")
                        .font(DS.Typo.caption.weight(.medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .padding(DS.Spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(DS.Palette.orange.opacity(0.10), lineWidth: 0.75)
        }
    }

    @ViewBuilder
    private var diaryContent: some View {
        if loading && diaries.isEmpty {
            AppCard(radius: DS.Radius.panel) {
                HStack(spacing: DS.Spacing.gap) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("大橘正在翻日记本")
                            .font(DS.Typo.cardTitle)
                        Text("很快就好，纸页还有一点点沙沙响。")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .frame(minHeight: 72)
            }
        } else if diaries.isEmpty {
            emptyState
        } else {
            if let errorText {
                StatusBanner(text: errorText, kind: .warning)
            }

            AppSectionHeader(title: "最新一页", subtitle: "先看看大橘最近记住了什么")
            NavigationLink {
                DajuDiaryDetailView(diary: diaries[0], onRegenerated: replaceDiary)
                    .appSubpageChrome()
            } label: {
                DajuDiaryFeaturedCard(diary: diaries[0])
            }
            .buttonStyle(PressableStyle())

            if diaries.count > 1 {
                AppSectionHeader(title: "往日爪印", subtitle: "这些普通日子，都没有被忘记")
                ForEach(Array(diaries.dropFirst())) { diary in
                    NavigationLink {
                        DajuDiaryDetailView(diary: diary, onRegenerated: replaceDiary)
                            .appSubpageChrome()
                    } label: {
                        DajuDiaryArchiveRow(diary: diary)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var emptyState: some View {
        AppCard(radius: DS.Radius.panel) {
            VStack(spacing: 16) {
                AppEmptyState(
                    errorText == nil ? "还没有留下爪印" : "日记本暂时打不开",
                    systemImage: errorText == nil ? "book.closed" : "wifi.exclamationmark",
                    detail: errorText ?? "前一个作息日有共同聊天时，大橘会自动写下第一篇日记。")
                    .frame(minHeight: 210)

                Button(errorText == nil ? "看看昨天能不能补写" : "重新加载") {
                    Task {
                        if errorText == nil { await ensureYesterday() } else { await reload() }
                    }
                }
                .font(DS.Typo.button)
                .buttonStyle(.borderedProminent)
                .tint(DS.Palette.accent)
                .disabled(ensuring || store.session == nil)
            }
        }
    }

    private var privacyNote: some View {
        Label(
            "日记只取材于你们的共同聊天，不会读取任何一方与大橘的私人对话。",
            systemImage: "lock.shield.fill")
            .font(DS.Typo.caption)
            .foregroundStyle(DS.Palette.textSecondary)
            .lineSpacing(2)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var ensureToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await ensureYesterday() }
            } label: {
                if ensuring {
                    ProgressView()
                } else {
                    Label("补写昨天", systemImage: "wand.and.stars")
                }
            }
            .disabled(ensuring || store.session == nil)
            .accessibilityLabel(ensuring ? "正在补写昨天的日记" : "补写昨天的日记")
        }
    }

    private func reload() async {
        guard let token = store.session?.token else {
            loading = false
            errorText = "登录后才能打开你们的共同日记。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            diaries = try await repository.list(token: token)
            errorText = nil
        } catch {
            errorText = "加载失败，请稍后再试。"
        }
    }

    private func ensureYesterday() async {
        guard let token = store.session?.token else { return }
        ensuring = true
        noticeText = nil
        defer { ensuring = false }
        do {
            if let diary = try await repository.ensureYesterday(token: token) {
                if !diaries.contains(where: { $0.id == diary.id }) {
                    diaries.insert(diary, at: 0)
                } else {
                    diaries = diaries.map { $0.dayKey == diary.dayKey ? diary : $0 }
                }
                diaries.sort { $0.dayKey > $1.dayKey }
                errorText = nil
                noticeKind = .success
                DS.Anim.withMotion(DS.Anim.spring) {
                    noticeText = "昨天的日记已经收进记忆簿了。"
                }
            } else {
                noticeKind = .info
                noticeText = "昨天的共同聊天还不够形成一篇日记，等多留下一些小事再来看看。"
            }
        } catch {
            noticeKind = .warning
            noticeText = "补写没有成功，稍后再试一次吧。"
        }
    }

    private func replaceDiary(_ diary: DajuDiary) {
        diaries = diaries.map { $0.dayKey == diary.dayKey ? diary : $0 }
        if !diaries.contains(where: { $0.dayKey == diary.dayKey }) {
            diaries.append(diary)
        }
        diaries.sort { $0.dayKey > $1.dayKey }
    }
}

private struct DajuDiaryFeaturedCard: View {
    let diary: DajuDiary

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [DS.Palette.cardSurface, DS.Palette.orange.opacity(0.08), DS.Palette.pink.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            Text("“")
                .font(.system(size: 116, weight: .black, design: .serif))
                .foregroundStyle(DS.Palette.orange.opacity(0.08))
                .offset(x: 5, y: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label(diary.displayDate, systemImage: "calendar")
                        .font(DS.Typo.caption.weight(.semibold))
                        .foregroundStyle(DS.Palette.orange)
                    Spacer(minLength: 8)
                    Image(systemName: "pawprint.fill")
                        .foregroundStyle(DS.Palette.orange.opacity(0.72))
                }

                Text(diary.title)
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.leading)

                Text(diary.previewText)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineSpacing(5)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text("翻开这一页")
                    Image(systemName: "arrow.right")
                }
                .font(DS.Typo.sectionLabel)
                .foregroundStyle(DS.Palette.accent)
            }
            .padding(DS.Spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(DS.Palette.orange.opacity(0.12), lineWidth: 0.75)
        }
        .shadow(color: DS.Surface.shadow, radius: DS.Surface.softShadowRadius, y: DS.Surface.softShadowY)
    }
}

private struct DajuDiaryArchiveRow: View {
    let diary: DajuDiary

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 1) {
                Text(diary.monthText)
                    .font(DS.Typo.micro)
                    .foregroundStyle(DS.Palette.orange)
                Text(diary.dayNumberText)
                    .font(.system(.title2, design: .rounded).weight(.heavy))
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            .frame(width: 54, height: 62)
            .background(DS.Palette.orange.opacity(0.10), in: RoundedRectangle(
                cornerRadius: DS.Radius.control, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(diary.title)
                    .font(DS.Typo.cardTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                Text(diary.previewText)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(14)
        .background(DS.Palette.cardSurface, in: RoundedRectangle(
            cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .stroke(DS.Palette.hairline, lineWidth: 0.5)
        }
    }
}

private struct DajuDiaryDetailView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var diary: DajuDiary
    @State private var isRegenerating = false
    @State private var showsRegenerateConfirmation = false
    @State private var regenerateError: String?
    private let onRegenerated: (DajuDiary) -> Void
    private let repository = DajuDiaryRepository()

    init(diary: DajuDiary, onRegenerated: @escaping (DajuDiary) -> Void) {
        _diary = State(initialValue: diary)
        self.onRegenerated = onRegenerated
    }

    var body: some View {
        ZStack {
            AppPageBackground()
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("DAJU'S DIARY")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1.8)
                                    .foregroundStyle(DS.Palette.orange)
                                Text(diary.displayDate)
                                    .font(DS.Typo.caption)
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "pawprint.fill")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(
                                    LinearGradient(
                                        colors: [DS.Palette.orange, DS.Palette.pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing),
                                    in: Circle())
                                .shadow(color: DS.Palette.orange.opacity(0.20), radius: 10, y: 5)
                        }

                        Text(diary.title)
                            .font(.system(.largeTitle, design: .serif).weight(.bold))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Rectangle()
                            .fill(LinearGradient(
                                colors: [DS.Palette.orange.opacity(0.62), DS.Palette.pink.opacity(0.10), .clear],
                                startPoint: .leading,
                                endPoint: .trailing))
                            .frame(height: 1)

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(diary.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                                Text(paragraph)
                                    .font(.system(.body, design: .serif))
                                    .foregroundStyle(DS.Palette.textPrimary)
                                    .lineSpacing(6)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("第 \(index + 1) 段，\(paragraph)")
                            }
                        }
                        .textSelection(.enabled)

                        HStack(spacing: 10) {
                            Rectangle()
                                .fill(DS.Palette.orange.opacity(0.20))
                                .frame(height: 1)
                            Label("大橘收好这一页了", systemImage: "pawprint.fill")
                                .font(DS.Typo.caption.weight(.medium))
                                .foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize()
                            Rectangle()
                                .fill(DS.Palette.orange.opacity(0.20))
                                .frame(height: 1)
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                }
                .background {
                    ZStack {
                        DS.Palette.cardSurface
                        LinearGradient(
                            colors: [DS.Palette.orange.opacity(0.035), .clear, DS.Palette.pink.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .stroke(DS.Palette.orange.opacity(0.10), lineWidth: 0.75)
                }
                .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
                .padding(.horizontal, DS.Spacing.page)
                .padding(.vertical, DS.Spacing.section)
                .appReadableWidth(680)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(diary.monthDayText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsRegenerateConfirmation = true
                } label: {
                    if isRegenerating {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                }
                .disabled(isRegenerating || store.session == nil)
                .accessibilityLabel(isRegenerating ? "正在重新整理这篇日记" : "重新整理这篇日记")
            }
        }
        .confirmationDialog(
            "重新整理这一天？",
            isPresented: $showsRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("按原聊天重新整理") {
                Task { await regenerate() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("大橘会重新挑选这一天最值得记住的主线，并覆盖当前这一页。原聊天不会改变。")
        }
        .alert(
            "重新整理失败",
            isPresented: Binding(
                get: { regenerateError != nil },
                set: { if !$0 { regenerateError = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(regenerateError ?? "请稍后再试。")
        }
    }

    private func regenerate() async {
        guard let token = store.session?.token else {
            regenerateError = "登录后才能重新整理日记。"
            return
        }
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            guard let updated = try await repository.regenerate(token: token, dayKey: diary.dayKey) else {
                regenerateError = "这一天暂时没有足够的共同聊天素材。"
                return
            }
            diary = updated
            onRegenerated(updated)
            Haptics.light()
        } catch {
            regenerateError = "没有整理成功，请稍后再试。"
        }
    }
}
