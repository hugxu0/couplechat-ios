import SwiftUI

// 记录页「我们」：在一起天数（主题渐变大卡）、见面/吵架计数、
// 聊天统计（近10天/月度切换、点柱查看）、大橘日记、今日推荐。
// 数据：纪念日走 shared["dates"]（两人共享），统计/日记/推荐走 REST。

struct RecordsView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var stats: StatsResponse?
    @State private var daily: DailyContent?
    @State private var showDateEditor = false
    @State private var recommendBusy = false
    @State private var recommendSent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    heroCard
                    counterRow
                    ChatStatsCard(stats: stats)
                    diaryCard
                    recommendCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await reload() }
            .task { await reload() }
            .sheet(isPresented: $showDateEditor) {
                DateEditorSheet()
                    .presentationDetents([.medium])
            }
        }
    }

    private func reload() async {
        async let s = store.fetchStats()
        async let d = store.fetchDaily()
        let (newStats, newDaily) = await (s, d)
        withAnimation(DS.Anim.ease) {
            if let newStats { stats = newStats }
            if let newDaily { daily = newDaily }
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

    // MARK: - 见面 / 吵架计数
    private var counterRow: some View {
        HStack(spacing: DS.Spacing.gap) {
            counterCard(
                icon: "figure.2.arms.open",
                title: "距离上次见面",
                days: CoupleDates.daysSince(store.coupleDates.lastMeet),
                resetLabel: "今天见面啦",
                onReset: { resetDate(\.lastMeet) })
            counterCard(
                icon: "cloud.sun",
                title: "距离上次吵架",
                days: CoupleDates.daysSince(store.coupleDates.lastFight),
                resetLabel: "记一下",
                onReset: { resetDate(\.lastFight) })
        }
    }

    private func counterCard(icon: String, title: String, days: Int?, resetLabel: String, onReset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            if let days {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(days)")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .contentTransition(.numericText())
                    Text("天")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            } else {
                Text("未设置")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.6))
                    .padding(.vertical, 5)
            }
            Button {
                Haptics.medium()
                withAnimation(DS.Anim.spring) { onReset() }
            } label: {
                Text(resetLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.accent.color.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.tile + 4)
    }

    private func resetDate(_ keyPath: WritableKeyPath<CoupleDates, String?>) {
        var dates = store.coupleDates
        dates[keyPath: keyPath] = Self.today()
        store.saveCoupleDates(dates)
    }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: Date())
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
                if daily?.recommend != nil {
                    Button {
                        Haptics.light()
                        sendRecommendToPartner()
                    } label: {
                        Label(recommendSent ? "已发送" : "给 TA 推荐", systemImage: recommendSent ? "checkmark" : "paperplane.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(recommendSent)
                }
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

    private func sendRecommendToPartner() {
        guard let rec = daily?.recommend else { return }
        store.sendText("🎁 大橘的今日推荐：【\(rec.category)】\(rec.title)\n\(rec.reason)", channel: .couple)
        withAnimation(DS.Anim.spring) { recommendSent = true }
    }
}

// MARK: - 聊天统计卡（近10天 / 月度）

private struct ChatStatsCard: View {
    let stats: StatsResponse?
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    private enum Mode: String, CaseIterable { case days = "近 10 天", months = "月度" }
    @State private var mode: Mode = .days
    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            picker
            if let stats {
                chart(stats)
                legendRow(stats)
            } else {
                HStack {
                    Spacer()
                    ProgressView().padding(.vertical, 40)
                    Spacer()
                }
            }
        }
        .padding(DS.Spacing.card)
        .dsCard()
        .onChange(of: mode) { selectedIndex = nil }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("聊天时光")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            if let stats {
                let (label, total, delta) = headline(stats)
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
    }

    /// 头部数字：选中了柱就显示选中项，否则显示最新一项（今天/本月）+ 环比
    private func headline(_ stats: StatsResponse) -> (String, Int, Int?) {
        switch mode {
        case .days:
            let items = stats.days
            let idx = selectedIndex ?? items.count - 1
            guard items.indices.contains(idx) else { return ("", 0, nil) }
            let delta = idx > 0 ? items[idx].total - items[idx - 1].total : nil
            let label = idx == items.count - 1 ? "今天" : String(items[idx].date.suffix(5))
            return (label, items[idx].total, delta)
        case .months:
            let items = stats.months
            let idx = selectedIndex ?? items.count - 1
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

    // MARK: 双色柱状图
    @ViewBuilder
    private func chart(_ stats: StatsResponse) -> some View {
        let bars: [(label: String, counts: [String: Int])] = mode == .days
            ? stats.days.map { (label: String($0.weekday), counts: $0.counts) }
            : stats.months.map { (label: String(Int($0.month.suffix(2)) ?? 0) + "月", counts: $0.counts) }
        let maxTotal = max(bars.map { $0.counts.values.reduce(0, +) }.max() ?? 1, 1)
        let me = store.session?.username ?? "xu"
        let partner = store.partner?.username ?? (me == "xu" ? "si" : "xu")

        HStack(alignment: .bottom, spacing: mode == .days ? 8 : 6) {
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                let mine = Double(bar.counts[me] ?? 0)
                let hers = Double(bar.counts[partner] ?? 0)
                let selected = selectedIndex == index || (selectedIndex == nil && index == bars.count - 1)
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Capsule().fill(DS.Palette.member(partner))
                                .frame(height: geo.size.height * hers / Double(maxTotal))
                            Capsule().fill(DS.Palette.member(me))
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
    }

    // MARK: 图例（选中项的双方条数）
    @ViewBuilder
    private func legendRow(_ stats: StatsResponse) -> some View {
        let counts: [String: Int] = {
            switch mode {
            case .days:
                let idx = selectedIndex ?? stats.days.count - 1
                return stats.days.indices.contains(idx) ? stats.days[idx].counts : [:]
            case .months:
                let idx = selectedIndex ?? stats.months.count - 1
                return stats.months.indices.contains(idx) ? stats.months[idx].counts : [:]
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

// MARK: - 纪念日编辑

struct DateEditorSheet: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var together = Date()
    @State private var lastMeet = Date()
    @State private var lastFight = Date()
    @State private var hasTogether = false
    @State private var hasMeet = false
    @State private var hasFight = false

    var body: some View {
        NavigationStack {
            Form {
                Section("在一起的日子") {
                    Toggle("已设置", isOn: $hasTogether.animation())
                    if hasTogether {
                        DatePicker("纪念日", selection: $together, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section("上次见面") {
                    Toggle("已设置", isOn: $hasMeet.animation())
                    if hasMeet {
                        DatePicker("日期", selection: $lastMeet, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section("上次吵架") {
                    Toggle("已设置", isOn: $hasFight.animation())
                    if hasFight {
                        DatePicker("日期", selection: $lastFight, in: ...Date(), displayedComponents: .date)
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
        if let m = dates.lastMeet, let d = Self.formatter.date(from: m) {
            lastMeet = d
            hasMeet = true
        }
        if let f = dates.lastFight, let d = Self.formatter.date(from: f) {
            lastFight = d
            hasFight = true
        }
    }

    private func save() {
        Haptics.medium()
        store.saveCoupleDates(CoupleDates(
            together: hasTogether ? Self.formatter.string(from: together) : nil,
            lastMeet: hasMeet ? Self.formatter.string(from: lastMeet) : nil,
            lastFight: hasFight ? Self.formatter.string(from: lastFight) : nil))
    }
}
