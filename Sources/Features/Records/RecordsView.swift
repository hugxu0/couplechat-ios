import SwiftUI

// 记录页「我们」：在一起天数（主题渐变大卡）、纪念日/倒数日卡片网格（只读展示，
// 增删改统一在「我的 → 日期设置」里做）、聊天统计（近30天/月度切换、横向滚动看更早、点柱查看）、
// 大橘日记、今日推荐。
// 数据：纪念日走 shared["dates"]/shared["anniversaries"]（两人共享），
// 聊天统计聚合自本地缓存的完整聊天记录，日记/推荐走 REST。

struct RecordsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var daily: DailyContent?
    @State private var showDateEditor = false
    @State private var recommendBusy = false
    @State private var recommendSent = false
    @State private var showRecommendComposer = false
    @State private var incomingRecommend: PartnerRecommend?
    // 已看过的对方推荐 id，避免每次进页面重复弹
    @AppStorage("records.seenRecommendId") private var seenRecommendId = ""

    private var myUsername: String { store.session?.username ?? "" }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: DS.Spacing.gap) {
                        RootPageHeader("记录", subtitle: "我们的共同时间")
                        .padding(.horizontal, -DS.Spacing.page)
                        heroCard
                        anniversaryGrid
                        ChatStatsCard()
                        recommendCard
                        diaryCard
                    }
                    .padding(.horizontal, DS.Spacing.page)
                    .padding(.bottom, 90)
                }
                .scrollIndicators(.hidden)

                if let rec = incomingRecommend {
                    PartnerRecommendPopup(recommend: rec) {
                        seenRecommendId = rec.id
                        DS.Anim.withMotion(DS.Anim.springFast) {
                            incomingRecommend = nil
                        }
                    }
                    .zIndex(5)
                }
            }
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await reload() }
            .task { await reload() }
            .onAppear { checkIncomingRecommend() }
            .onChange(of: partnerRecommendId) { checkIncomingRecommend() }
            .sheet(isPresented: $showDateEditor) {
                DateEditorSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showRecommendComposer) {
                RecommendComposerSheet { text in
                    sendPartnerRecommend(text)
                }
                .presentationDetents([.medium])
            }
        }
    }

    // MARK: - 给 TA 推荐（shared 状态同步，对方打开记录页弹窗）

    private var partnerRecommendId: String? {
        store.sharedValue("partner_recommend")?["id"] as? String
    }

    private func checkIncomingRecommend() {
        guard let value = store.sharedValue("partner_recommend"),
              let rec = PartnerRecommend(dict: value),
              rec.from != myUsername,
              rec.id != seenRecommendId,
              incomingRecommend?.id != rec.id else { return }
        Haptics.medium()
        DS.Anim.withMotion(DS.Anim.spring) {
            incomingRecommend = rec
        }
    }

    private func sendPartnerRecommend(_ text: String) {
        store.setShared("partner_recommend", value: [
            "id": UUID().uuidString,
            "from": myUsername,
            "fromName": store.session?.name ?? "TA",
            "text": text,
            "ts": Date().timeIntervalSince1970 * 1000,
        ])
        withAnimation(DS.Anim.spring) { recommendSent = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(DS.Anim.ease) { recommendSent = false }
            }
        }
    }

    private func reload() async {
        guard let token = store.auth.session?.token,
              let newDaily = await store.dailyContent.fetch(token: token) else { return }
        withAnimation(DS.Anim.ease) {
            daily = newDaily
        }
    }

    // MARK: - 在一起天数（主题渐变大卡）
    private var heroCard: some View {
        Button {
            Haptics.light()
            showDateEditor = true
        } label: {
            VStack(spacing: 6) {
                Text("我们在一起")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                if let days = CoupleDates.daysSince(store.coupleDates.together) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(days)")
                            .font(.system(size: 68, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text("天")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .foregroundStyle(.white)
                } else {
                    Text("点击设置纪念日")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 16)
                }
                Text("陪伴是很长情的告白")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                ZStack {
                    theme.accent.gradient
                    // 角落里的柔光心形，低调点缀
                    Image(systemName: "heart.fill")
                        .font(.system(size: 120))
                        .foregroundStyle(.white.opacity(0.10))
                        .rotationEffect(.degrees(-14))
                        .offset(x: 130, y: 34)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .shadow(color: theme.accent.color.opacity(0.35), radius: 16, y: 8)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - 纪念日 / 倒数日（只读展示，增删改在「我的 → 日期设置」里）
    @ViewBuilder
    private var anniversaryGrid: some View {
        if !store.anniversaries.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Spacing.gap) {
                ForEach(store.anniversaries) { entry in
                    anniversaryCard(entry)
                }
            }
        }
    }

    private func anniversaryCard(_ entry: AnniversaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: entry.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
            }
            if let days = entry.days {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(days)")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .contentTransition(.numericText())
                    Text(entry.direction == .up ? "天" : "天后")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            } else {
                Text("未设置")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.6))
                    .padding(.vertical, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.card)
        .dsCard()
    }

    // MARK: - 大橘日记
    @ViewBuilder
    private var diaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("🐱")
                    .font(.system(size: 22))
                Text("大橘日记")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                if let diary = daily?.diary {
                    Text(diary.date.suffix(5).replacingOccurrences(of: "-", with: "/"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            if let diary = daily?.diary {
                Text(diary.text)
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textPrimary.opacity(0.9))
                    .lineSpacing(5)
            } else {
                Text("大橘还没写日记喵，聊过一天之后再来看吧。")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.card)
        .dsCard()
    }

    // MARK: - 今日推荐
    @ViewBuilder
    private var recommendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日推荐")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Button {
                    Haptics.light()
                    showRecommendComposer = true
                } label: {
                    Label(recommendSent ? "已送达" : "给 TA 推荐", systemImage: recommendSent ? "checkmark" : "gift.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(PressableStyle())
                .disabled(recommendSent)
            }

            if let rec = daily?.recommend {
                HStack(spacing: 8) {
                    Text(rec.category)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(theme.accent.color.opacity(0.12))
                        .clipShape(Capsule())
                    Text(rec.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(DS.Palette.textPrimary)
                }
                Text(rec.reason)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineSpacing(4)

                Button {
                    Haptics.light()
                    regenerate()
                } label: {
                    HStack(spacing: 5) {
                        if recommendBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text("换一个")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(DS.Palette.innerSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(recommendBusy)
            } else {
                Text("大橘正在琢磨今天推荐点什么…")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.card)
        .dsCard()
    }

    private func regenerate() {
        recommendBusy = true
        recommendSent = false
        Task {
            guard let token = store.auth.session?.token else { return }
            let rec = await store.dailyContent.regenerateRecommendation(token: token)
            await MainActor.run {
                recommendBusy = false
                if let rec, let current = daily {
                    withAnimation(DS.Anim.spring) {
                        daily = DailyContent(diary: current.diary, recommend: rec)
                    }
                }
            }
        }
    }

}
