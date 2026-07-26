import SwiftUI

/// 图鉴：全部 84 张卡按稀有度分页浏览，已收集的显示彩色卡面与数量，
/// 未收集的显示剪影。快照每次轮询都带完整 catalog，此前从未展示过。
struct CardGameCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: CardGameSnapshot

    @State private var rarity: CardGameRarity = .common
    @State private var showPartner = false
    @State private var detailCard: CardGameDefinition?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    progressHeader
                    rarityPicker
                    grid
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 40)
                .appReadableWidth(880)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .navigationTitle("卡牌图鉴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $detailCard) { card in
                collectionDetail(card)
                    .presentationDetents([.medium])
            }
        }
    }

    private var ownedCounts: [String: Int] {
        let source = showPartner ? snapshot.partnerInventory : snapshot.inventory
        return Dictionary(
            source.map { ("\($0.cardKey)|\($0.rarity.rawValue)", $0.quantity) },
            uniquingKeysWith: +)
    }

    private var progressHeader: some View {
        let owned = ownedCounts
        let total = snapshot.catalog.count
        let collected = snapshot.catalog.filter { owned["\($0.key)|\($0.rarity.rawValue)"] != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(showPartner ? "TA 的收集" : "我的收集")
                    .font(DS.Typo.cardTitle)
                Spacer()
                Button {
                    Haptics.light()
                    showPartner.toggle()
                } label: {
                    Label(showPartner ? "看我的" : "看 TA 的", systemImage: "arrow.left.arrow.right")
                        .font(DS.Typo.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("\(collected)")
                    .font(DS.Typo.displayNumber.monospacedDigit())
                    .foregroundStyle(DS.Palette.purple)
                Text("/ \(total) 张")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            ProgressView(value: Double(collected), total: Double(max(1, total)))
                .tint(DS.Palette.purple)
        }
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.panel)
    }

    private var rarityPicker: some View {
        HStack(spacing: 7) {
            ForEach([CardGameRarity.common, .rare, .epic, .legendary], id: \.self) { value in
                Button {
                    Haptics.light()
                    rarity = value
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 7, weight: .black))
                        Text(value.title)
                            .font(DS.Typo.caption.weight(.semibold))
                    }
                    .foregroundStyle(rarity == value ? .white : value.tint)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        rarity == value ? value.tint : value.tint.opacity(0.1),
                        in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            Spacer()
        }
    }

    private var grid: some View {
        let owned = ownedCounts
        let cards = snapshot.catalog.filter { $0.rarity == rarity }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 12) {
            ForEach(cards, id: \.id) { card in
                let count = owned["\(card.key)|\(card.rarity.rawValue)"]
                Button {
                    Haptics.light()
                    detailCard = card
                } label: {
                    if let count {
                        CardFaceView(definition: card, quantity: count, compact: true)
                    } else {
                        silhouette(card)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func silhouette(_ card: CardGameDefinition) -> some View {
        VStack(spacing: 8) {
            Image(systemName: card.icon)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(DS.Palette.textTertiary.opacity(0.5))
            Text(card.title)
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("未收集")
                .font(DS.Typo.micro)
                .foregroundStyle(DS.Palette.textTertiary.opacity(0.7))
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(0.68, contentMode: .fit)
        .background(DS.Palette.fieldSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    DS.Palette.textTertiary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
    }

    private func collectionDetail(_ card: CardGameDefinition) -> some View {
        let count = ownedCounts["\(card.key)|\(card.rarity.rawValue)"]
        return VStack(spacing: 16) {
            CardFaceView(definition: card, quantity: count)
                .frame(maxWidth: 210)
            VStack(spacing: 6) {
                Text(card.summary)
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .multilineTextAlignment(.center)
                Text(count.map { "\(showPartner ? "TA" : "你")已收集 ×\($0)" } ?? "还没有抽到这张卡")
                    .font(DS.Typo.caption.weight(.semibold))
                    .foregroundStyle(count == nil ? DS.Palette.textTertiary : card.rarity.tint)
            }
            .padding(.horizontal, 22)
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppPageBackground())
    }
}
