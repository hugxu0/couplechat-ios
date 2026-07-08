import SwiftUI

// 记录页「我们」：在一起天数（主题渐变大卡）、纪念日/倒数日卡片网格（只读展示，
// 增删改统一在「我的 → 日期设置」里做）、聊天统计（近10天/月度切换、左右翻页看更早、点柱查看）、
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
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            incomingRecommend = nil
                        }
                    }
                    .zIndex(5)
                }
            }
            .background(DynamicGradientBackground().ignoresSafeArea())
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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
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
        guard let newDaily = await store.fetchDaily() else { return }
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
        .dsCard(radius: DS.Radius.tile + 4)
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
            let rec = await store.regenerateRecommendation()
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

// MARK: - 对方推荐的数据模型（存在 shared["partner_recommend"]）

struct PartnerRecommend: Equatable {
    let id: String
    let from: String
    let fromName: String
    let text: String
    let ts: Double

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let from = dict["from"] as? String,
              let text = dict["text"] as? String, !text.isEmpty else { return nil }
        self.id = id
        self.from = from
        self.fromName = dict["fromName"] as? String ?? "TA"
        self.text = text
        self.ts = (dict["ts"] as? NSNumber)?.doubleValue ?? 0
    }
}

// MARK: - 推荐输入弹层（自己写一条推荐发给对方）

private struct RecommendComposerSheet: View {
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeManager
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("推荐点什么给 TA？")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("一首歌、一部电影、一家店…TA 打开记录页就会看到")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)

                TextField("比如：新出的那部电影超好看，周末一起？", text: $text, axis: .vertical)
                    .focused($focused)
                    .lineLimit(3...6)
                    .font(.system(size: 16))
                    .padding(14)
                    .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { return }
                    Haptics.medium()
                    onSend(String(body.prefix(120)))
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gift.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("送出推荐")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.accent.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - 收到推荐的弹窗（对方送来的惊喜）

private struct PartnerRecommendPopup: View {
    let recommend: PartnerRecommend
    let onDismiss: () -> Void

    @EnvironmentObject private var theme: ThemeManager
    @State private var appeared = false

    var body: some View {
        ZStack {
            // 半透明暗背景，点击也可关闭
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // 顶部渐变礼物区
                ZStack {
                    theme.accent.gradient
                    VStack(spacing: 6) {
                        Text("🎁")
                            .font(.system(size: 44))
                            .scaleEffect(appeared ? 1.0 : 0.4)
                            .rotationEffect(.degrees(appeared ? 0 : -18))
                        Text("\(recommend.fromName) 给你推荐了")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .padding(.vertical, 22)

                    // 柔光装饰
                    Image(systemName: "sparkles")
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.16))
                        .offset(x: 110, y: -14)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.14))
                        .offset(x: -110, y: 20)
                }
                .frame(height: 118)

                // 推荐内容
                VStack(spacing: 18) {
                    Text(recommend.text)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                    Button {
                        Haptics.light()
                        onDismiss()
                    } label: {
                        Text("收到啦 💗")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(theme.accent.gradient, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
                }
                .background(DS.Palette.cardSurface)
            }
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .scaleEffect(appeared ? 1.0 : 0.82)
            .opacity(appeared ? 1.0 : 0)
            .padding(.horizontal, 36)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                appeared = true
            }
        }
    }
}

// MARK: - 聊天统计卡（近10天 / 月度，数据来自本地聊天缓存，支持左右翻页看更早）

private struct ChatStatsCard: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    private enum Mode: String, CaseIterable { case days = "近 10 天", months = "月度" }
    @State private var mode: Mode = .days
    @State private var selectedIndex: Int?
    @State private var buckets = ChatStore.LocalStatsBuckets(days: [], months: [])
    @State private var dayPage = 0
    @State private var monthPage = 0
    @State private var followLatestDay = true
    @State private var followLatestMonth = true

    private static let dayPageSize = 10
    private static let monthPageSize = 12

    private var dayPages: [[DayStat]] { Self.chunk(buckets.days, size: Self.dayPageSize) }
    private var monthPages: [[MonthStat]] { Self.chunk(buckets.months, size: Self.monthPageSize) }

    private static func chunk<T>(_ items: [T], size: Int) -> [[T]] {
        guard !items.isEmpty else { return [[]] }
        var pages: [[T]] = []
        var idx = 0
        while idx < items.count {
            let end = min(idx + size, items.count)
            pages.append(Array(items[idx..<end]))
            idx = end
        }
        return pages
    }

    private var dayPageBinding: Binding<Int> {
        Binding(
            get: { dayPage },
            set: { newValue in
                dayPage = newValue
                followLatestDay = newValue == dayPages.count - 1
            })
    }

    private var monthPageBinding: Binding<Int> {
        Binding(
            get: { monthPage },
            set: { newValue in
                monthPage = newValue
                followLatestMonth = newValue == monthPages.count - 1
            })
    }

    private var globalSelectedDayIndex: Int {
        let localCount = dayPages.indices.contains(dayPage) ? dayPages[dayPage].count : 0
        return dayPage * Self.dayPageSize + (selectedIndex ?? localCount - 1)
    }

    private var globalSelectedMonthIndex: Int {
        let localCount = monthPages.indices.contains(monthPage) ? monthPages[monthPage].count : 0
        return monthPage * Self.monthPageSize + (selectedIndex ?? localCount - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            picker
            chart
            legendRow
        }
        .padding(DS.Spacing.card)
        .dsCard()
        .onChange(of: mode) { selectedIndex = nil }
        .onAppear {
            refreshBuckets()
        }
        .onChange(of: store.messagesByChannel) { _, _ in
            refreshBuckets()
        }
    }

    private func refreshBuckets() {
        buckets = store.localStats(for: .couple)
        if followLatestDay { dayPage = max(0, dayPages.count - 1) }
        if followLatestMonth { monthPage = max(0, monthPages.count - 1) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("聊天时光")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            let (label, total, delta) = headline()
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DS.Palette.textSecondary)
            Text("\(total)")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
                .contentTransition(.numericText())
            if let delta, delta != 0 {
                Text(delta > 0 ? "↑\(delta)" : "↓\(-delta)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(delta > 0 ? DS.Palette.green : DS.Palette.pink)
            }
        }
    }

    /// 头部数字：选中了柱就显示选中项，否则显示当前页最新一项（今天/本月）+ 环比（跨页也按整体序列对比）
    private func headline() -> (String, Int, Int?) {
        switch mode {
        case .days:
            let items = buckets.days
            let idx = globalSelectedDayIndex
            guard items.indices.contains(idx) else { return ("", 0, nil) }
            let delta = idx > 0 ? items[idx].total - items[idx - 1].total : nil
            let label = idx == items.count - 1 ? "今天" : String(items[idx].date.suffix(5))
            return (label, items[idx].total, delta)
        case .months:
            let items = buckets.months
            let idx = globalSelectedMonthIndex
            guard items.indices.contains(idx) else { return ("", 0, nil) }
            let delta = idx > 0 ? items[idx].total - items[idx - 1].total : nil
            let label = idx == items.count - 1 ? "本月" : String(items[idx].month.suffix(2)) + "月"
            return (label, items[idx].total, delta)
        }
    }

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    Haptics.selection()
                    withAnimation(DS.Anim.springFast) { mode = m }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(mode == m ? .white : DS.Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(mode == m ? AnyShapeStyle(theme.accent.color) : AnyShapeStyle(DS.Palette.innerSurface))
                        .clipShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
        }
    }

    // MARK: 双色柱状图（左右滑动翻页看更早的日子/月份，页数由本地聊天记录的实际时长决定，没有上限）
    @ViewBuilder
    private var chart: some View {
        let me = store.session?.username ?? "xu"
        let partner = store.partner?.username ?? (me == "xu" ? "si" : "xu")

        switch mode {
        case .days:
            TabView(selection: dayPageBinding) {
                ForEach(Array(dayPages.enumerated()), id: \.offset) { pageIndex, page in
                    let bars: [(label: String, counts: [String: Int])] = page.map { (label: $0.weekday, counts: $0.counts) }
                    barsView(bars, me: me, partner: partner)
                        .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 140)
        case .months:
            TabView(selection: monthPageBinding) {
                ForEach(Array(monthPages.enumerated()), id: \.offset) { pageIndex, page in
                    let bars: [(label: String, counts: [String: Int])] = page.map { (label: String(Int($0.month.suffix(2)) ?? 0) + "月", counts: $0.counts) }
                    barsView(bars, me: me, partner: partner)
                        .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 140)
        }
    }

    private func barsView(_ bars: [(label: String, counts: [String: Int])], me: String, partner: String) -> some View {
        let maxTotal = max(bars.map { $0.counts.values.reduce(0, +) }.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: mode == .days ? 8 : 6) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                let mine = Double(bar.counts[me] ?? 0)
                let hers = Double(bar.counts[partner] ?? 0)
                let selected = selectedIndex == index || (selectedIndex == nil && index == bars.count - 1)
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().fill(DS.Palette.member(partner))
                                .frame(height: geo.size.height * hers / Double(maxTotal))
                            Rectangle().fill(DS.Palette.member(me))
                                .frame(height: geo.size.height * mine / Double(maxTotal))
                        }
                    }
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .background(DS.Palette.innerSurface.opacity(0.7))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(selected ? theme.accent.color : .clear, lineWidth: 2)
                    )
                    Text(bar.label)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? theme.accent.color : DS.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.selection()
                    withAnimation(DS.Anim.springFast) {
                        selectedIndex = selectedIndex == index ? nil : index
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: 图例（选中项的双方条数）
    @ViewBuilder
    private var legendRow: some View {
        let counts: [String: Int] = {
            switch mode {
            case .days:
                let idx = globalSelectedDayIndex
                return buckets.days.indices.contains(idx) ? buckets.days[idx].counts : [:]
            case .months:
                let idx = globalSelectedMonthIndex
                return buckets.months.indices.contains(idx) ? buckets.months[idx].counts : [:]
            }
        }()
        let me = store.session
        let partner = store.partner

        HStack(spacing: 18) {
            if let me {
                legend(color: DS.Palette.member(me.username), name: me.name, count: counts[me.username] ?? 0)
            }
            if let partner {
                legend(color: DS.Palette.member(partner.username), name: partner.name, count: counts[partner.username] ?? 0)
            }
            Spacer()
        }
    }

    private func legend(color: Color, name: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
            Text("\(count)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Palette.textPrimary)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - 日期设置（「在一起」纪念日 + 自由添加的纪念日/倒数日的增删改，统一在这里管理）

struct DateEditorSheet: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var together = Date()
    @State private var hasTogether = false
    @State private var editingAnniversary: AnniversaryEntry?
    @State private var showAddAnniversary = false

    var body: some View {
        NavigationStack {
            Form {
                Section("在一起的日子") {
                    Toggle("已设置", isOn: $hasTogether.animation())
                    if hasTogether {
                        DatePicker("纪念日", selection: $together, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section("纪念日 / 倒数日") {
                    ForEach(store.anniversaries) { entry in
                        Button {
                            Haptics.light()
                            editingAnniversary = entry
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.accent.color)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 15))
                                        .foregroundStyle(DS.Palette.textPrimary)
                                    Text(entry.direction == .up ? "累计天数" : "倒数纪念日")
                                        .font(.system(size: 12))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                Spacer()
                                if let days = entry.days {
                                    Text("\(days)\(entry.direction == .up ? "天" : "天后")")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteAnniversaries)

                    Button {
                        Haptics.light()
                        showAddAnniversary = true
                    } label: {
                        Label("添加纪念日", systemImage: "plus.circle.fill")
                            .foregroundStyle(theme.accent.color)
                    }
                }
            }
            .navigationTitle("日期设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
            .sheet(item: $editingAnniversary) { entry in
                AnniversaryEditorSheet(entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAddAnniversary) {
                AnniversaryEditorSheet(entry: nil)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private func load() {
        let dates = store.coupleDates
        if let t = dates.together, let d = Self.formatter.date(from: t) {
            together = d
            hasTogether = true
        }
    }

    private func save() {
        Haptics.medium()
        var dates = store.coupleDates
        dates.together = hasTogether ? Self.formatter.string(from: together) : nil
        store.saveCoupleDates(dates)
    }

    private func deleteAnniversaries(at offsets: IndexSet) {
        var items = store.anniversaries
        items.remove(atOffsets: offsets)
        store.saveAnniversaries(items)
    }
}

// MARK: - 自由添加的纪念日 / 倒数日编辑

struct AnniversaryEditorSheet: View {
    let entry: AnniversaryEntry?

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var date = Date()
    @State private var direction: AnniversaryEntry.Direction = .up
    @State private var icon = Self.iconOptions.first!

    private static let iconOptions = [
        "heart.fill", "gift.fill", "airplane", "birthday.cake.fill",
        "figure.2.arms.open", "moon.stars.fill", "cloud.sun", "message.fill",
    ]

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private var isEditing: Bool { entry != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("比如：纪念日 / 生日 / 旅行倒数", text: $title)
                }
                Section("类型") {
                    Picker("类型", selection: $direction) {
                        Text("累计天数").tag(AnniversaryEntry.Direction.up)
                        Text("倒数纪念日").tag(AnniversaryEntry.Direction.down)
                    }
                    .pickerStyle(.segmented)
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                }
                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { name in
                            Button {
                                Haptics.selection()
                                icon = name
                            } label: {
                                Image(systemName: name)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(icon == name ? .white : theme.accent.color)
                                    .frame(width: 44, height: 44)
                                    .background(icon == name ? AnyShapeStyle(theme.accent.color) : AnyShapeStyle(theme.accent.color.opacity(0.12)))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.vertical, 6)
                }
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            Haptics.medium()
                            deleteEntry()
                            dismiss()
                        } label: {
                            Text("删除纪念日")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑纪念日" : "添加纪念日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let entry else { return }
        title = entry.title
        direction = entry.direction
        icon = entry.icon
        if let d = Self.formatter.date(from: entry.date) {
            date = d
        }
    }

    private func save() {
        Haptics.medium()
        var items = store.anniversaries
        let dateString = Self.formatter.string(from: date)
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        if let entry, let idx = items.firstIndex(where: { $0.id == entry.id }) {
            items[idx] = AnniversaryEntry(id: entry.id, title: trimmedTitle, date: dateString, direction: direction, icon: icon)
        } else {
            items.append(AnniversaryEntry(title: trimmedTitle, date: dateString, direction: direction, icon: icon))
        }
        store.saveAnniversaries(items)
    }

    private func deleteEntry() {
        guard let entry else { return }
        var items = store.anniversaries
        items.removeAll { $0.id == entry.id }
        store.saveAnniversaries(items)
    }
}
