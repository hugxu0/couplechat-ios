import SwiftUI

// 记录页：在一起天数、见面/吵架计数、聊天统计柱状图。假数据。

struct RecordsView: View {
    private let week: [(day: String, mine: Double, hers: Double)] = [
        ("六", 0.10, 0.12), ("日", 0.12, 0.14), ("一", 0.08, 0.14),
        ("二", 0.18, 0.16), ("三", 0.22, 0.18), ("四", 0.10, 0.10),
        ("五", 0.12, 0.16), ("六", 0.30, 0.28), ("日", 0.20, 0.24),
        ("今", 0.46, 0.52),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    daysCard
                    HStack(spacing: DS.Spacing.gap) {
                        counterCard(title: "距离上次见面已经", value: "24")
                        counterCard(title: "距离上次吵架已经", value: "2")
                    }
                    chatStatsCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var daysCard: some View {
        VStack(spacing: 8) {
            Text("我们在一起的第")
                .font(.system(size: 15))
                .foregroundStyle(DS.Palette.textSecondary)
            Text("432")
                .font(.system(size: 72, weight: .heavy))
                .foregroundStyle(DS.Palette.accent)
                .contentTransition(.numericText())
            Text("天").font(.system(size: 16))
                .foregroundStyle(DS.Palette.textSecondary)
            Text("陪伴是很长情的告白。")
                .font(.system(size: 14))
                .foregroundStyle(DS.Palette.textSecondary.opacity(0.8))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .dsCard()
    }

    private func counterCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Palette.textPrimary)
            Text(value)
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(DS.Palette.accent)
            Text("天了")
                .font(.system(size: 14))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.card)
        .dsCard()
    }

    private var chatStatsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("聊天时光")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text("1616").font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("条").font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
                Text("↑ 667").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.green)
            }

            // 双色柱状图
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                Capsule().fill(DS.Palette.pink)
                                    .frame(height: geo.size.height * item.hers)
                                Capsule().fill(DS.Palette.blue)
                                    .frame(height: geo.size.height * item.mine)
                            }
                        }
                        .frame(height: 110)
                        .background(Color.white.opacity(0.6))
                        .clipShape(Capsule())
                        Text(item.day)
                            .font(.system(size: 12))
                            .foregroundStyle(item.day == "今" ? DS.Palette.accent : DS.Palette.textSecondary)
                    }
                }
            }

            HStack(spacing: 16) {
                legend(color: DS.Palette.blue, text: "小旭 750", trend: "↑ 325")
                legend(color: DS.Palette.pink, text: "小偲 866", trend: "↑ 342")
            }

            Button { } label: {
                Text("查看月度统计 ›")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(DS.Spacing.card)
        .dsCard()
    }

    private func legend(color: Color, text: String, trend: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Palette.textPrimary)
            Text(trend).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.green)
        }
    }
}
