import SwiftUI

// MARK: - 聊天统计卡（近30天 / 月度，数据来自本地聊天缓存，支持横向滚动）

struct ChatStatsCard: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    private enum Mode: String, CaseIterable { case days = "近 30 天", months = "月度" }
    @State private var mode: Mode = .days
    @State private var selectedIndex: Int?
    @State private var buckets = AppLocalStatsBuckets(days: [], months: [])
    private let repository = MomentsRepository()

    private var globalSelectedDayIndex: Int {
        selectedIndex ?? max(0, buckets.days.count - 1)
    }

    private var globalSelectedMonthIndex: Int {
        selectedIndex ?? max(0, buckets.months.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            picker
            chart
            legendRow
        }
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.card)
        .onChange(of: mode) { selectedIndex = nil }
        .task { await refreshBuckets() }
        .onReceive(store.messageStore.timelineStore.$messagesByChannel) { _ in
            Task { await refreshBuckets() }
        }
    }

    private func refreshBuckets() async {
        let local = await store.localData.stats(for: .couple)
        guard let token = store.session?.token,
              let remote = try? await repository.chatStats(token: token) else {
            buckets = local
            return
        }
        let dayCounts = Dictionary(grouping: remote.days, by: \.bucket)
        let monthCounts = Dictionary(grouping: remote.months, by: \.bucket)
        let localMonths = Dictionary(uniqueKeysWithValues: local.months.map { ($0.month, $0) })
        let monthKeys = Set(localMonths.keys).union(monthCounts.keys).sorted()
        buckets = AppLocalStatsBuckets(
            days: local.days.map { day in
                guard let rows = dayCounts[day.date] else { return day }
                return DayStat(date: day.date, weekday: day.weekday,
                               counts: Dictionary(uniqueKeysWithValues: rows.map { ($0.sender, $0.count) }))
            },
            months: monthKeys.map { key in
                guard let rows = monthCounts[key] else { return localMonths[key]! }
                return MonthStat(month: key,
                                 counts: Dictionary(uniqueKeysWithValues: rows.map { ($0.sender, $0.count) }))
            })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("聊天时光")
                .font(DS.Typo.cardTitle)
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            let (label, total, delta) = headline()
            Text(label)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Text("\(total)")
                .font(DS.Typo.displayNumber)
                .foregroundStyle(DS.Palette.textPrimary)
                .contentTransition(.numericText())
            if let delta, delta != 0 {
                Text(delta > 0 ? "↑\(delta)" : "↓\(-delta)")
                    .font(DS.Typo.sectionLabel)
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
                        .font(DS.Typo.sectionLabel)
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

    // MARK: 双色柱状图（固定柱宽，横向滚动展示完整日期/月度序列）
    @ViewBuilder
    private var chart: some View {
        let me = store.session?.username ?? "xu"
        let partner = store.partner?.username ?? (me == "xu" ? "si" : "xu")

        switch mode {
        case .days:
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    let bars: [(label: String, counts: [String: Int])] = buckets.days.map { (label: $0.weekday, counts: $0.counts) }
                    barsView(bars, me: me, partner: partner, barWidth: 28, lastId: "day-latest")
                }
                .onAppear { proxy.scrollTo("day-latest", anchor: .trailing) }
                .onChange(of: buckets.days.count) { _, _ in proxy.scrollTo("day-latest", anchor: .trailing) }
            }
            .frame(height: 92)
        case .months:
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    let bars: [(label: String, counts: [String: Int])] = buckets.months.map { (label: String(Int($0.month.suffix(2)) ?? 0) + "月", counts: $0.counts) }
                    barsView(bars, me: me, partner: partner, barWidth: 26, lastId: "month-latest")
                }
                .onAppear { proxy.scrollTo("month-latest", anchor: .trailing) }
                .onChange(of: buckets.months.count) { _, _ in proxy.scrollTo("month-latest", anchor: .trailing) }
            }
            .frame(height: 92)
        }
    }

    private func barsView(_ bars: [(label: String, counts: [String: Int])], me: String, partner: String, barWidth: CGFloat, lastId: String) -> some View {
        let maxTotal = max(bars.map { $0.counts.values.reduce(0, +) }.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 9) {
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
                    .frame(height: 64)
                    .frame(width: barWidth)
                    .background(DS.Palette.innerSurface.opacity(0.72))
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                selected ? theme.accent.color : .white.opacity(0.15),
                                lineWidth: selected ? 1.5 : 0.7)
                    }
                    Text(bar.label)
                        .font(DS.Typo.micro)
                        .foregroundStyle(selected ? theme.accent.color : DS.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .id(index == bars.count - 1 ? lastId : "\(lastId)-\(index)")
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
        .padding(.top, 3)
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
                .font(DS.Typo.secondary.weight(.medium))
                .foregroundStyle(DS.Palette.textSecondary)
            Text("\(count)")
                .font(DS.Typo.button)
                .foregroundStyle(DS.Palette.textPrimary)
                .contentTransition(.numericText())
        }
    }
}
