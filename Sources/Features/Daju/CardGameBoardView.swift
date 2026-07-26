import SwiftUI

/// 每日翻牌阵：六张背面卡对称双排（3+3、微倾角、待机浮动），点一张翻一张。
/// 翻牌序列：充能发光（掩盖网络请求）→ 升起多圈旋转 → 空中光色绽放揭晓
/// 稀有度 → 落回卡槽 → 分级爆发。已翻结果由服务端快照还原，跨设备一致。
struct CardGameBoardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: CardGameSnapshot
    let isBusy: Bool
    let onFlip: () async -> CardGameDraw?
    /// 点击立刻弹居中浮层（网络请求在充能期并行）；完成回调带结果落位，nil 表示失败还原槽位。
    let onReveal: (@escaping () async -> CardGameDraw?, @escaping (CardGameDraw?) -> Void) -> Void

    @State private var slotResults: [Int: CardGameDraw] = [:]
    @State private var flippingSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            boardArea
        }
        .padding(DS.Spacing.card)
        .dsCard(radius: DS.Radius.panel)
        .onChange(of: snapshot.day) { _, _ in
            slotResults = [:]
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日翻牌")
                    .font(DS.Typo.cardTitle)
                Text("点一张翻一张，北京时间每天 00:00 换新牌")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Text("\(snapshot.drawsUsed) / 6")
                .font(DS.Typo.displayNumber.monospacedDigit())
                .foregroundStyle(snapshot.drawsRemaining > 0 ? DS.Palette.purple : DS.Palette.textTertiary)
        }
    }

    private var boardArea: some View {
        GeometryReader { proxy in
            let cardWidth = min(104, (proxy.size.width - 44) / 3)
            let cardHeight = cardWidth / 0.68
            let positions = slotPositions(in: proxy.size, cardWidth: cardWidth, cardHeight: cardHeight)
            ZStack {
                ForEach(0..<6, id: \.self) { slot in
                    slotCard(slot: slot, width: cardWidth)
                        .position(positions[slot])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 348)
    }

    private func slotPositions(in size: CGSize, cardWidth: CGFloat, cardHeight: CGFloat) -> [CGPoint] {
        let gapX = cardWidth + 14
        let topY = cardHeight / 2 + 12
        let bottomY = topY + cardHeight + 18
        let centerX = size.width / 2
        // 3+3 对称双排。
        return [
            CGPoint(x: centerX - gapX, y: topY),
            CGPoint(x: centerX, y: topY),
            CGPoint(x: centerX + gapX, y: topY),
            CGPoint(x: centerX - gapX, y: bottomY),
            CGPoint(x: centerX, y: bottomY),
            CGPoint(x: centerX + gapX, y: bottomY),
        ]
    }

    @ViewBuilder
    private func slotCard(slot: Int, width: CGFloat) -> some View {
        let restored = restoredResult(slot: slot)
        let sessionResult = slotResults[slot]
        let result = sessionResult ?? restored
        let isFlipping = flippingSlot == slot

        Group {
            if let result, !isFlipping {
                revealedCard(result: result, width: width)
            } else if isFlipping {
                flipPlaceholder
            } else {
                faceDownCard(slot: slot, width: width)
            }
        }
        .frame(width: width)
    }

    private func revealedCard(result: CardGameDraw, width: CGFloat) -> some View {
        Group {
            if let card = result.card {
                CardFaceView(definition: card, compact: true)
            } else {
                CardMissFace()
            }
        }
        .frame(width: width)
        .transition(.identity)
    }

    private func faceDownCard(slot: Int, width: CGFloat) -> some View {
        let flippable = canFlip
        return TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let bob = reduceMotion ? 0 : sin(time * 1.4 + Double(slot) * 1.3) * 3.5
            Button {
                flip(slot: slot)
            } label: {
                CardBackView()
                    .rotationEffect(.degrees(slotTilt(slot)))
                    .offset(y: bob)
            }
            .buttonStyle(PressableStyle())
            .disabled(!flippable)
        }
    }

    /// 翻牌进行中：槽位留一个轻脉动的虚线空位，演出在屏幕中央的浮层里。
    private var flipPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                DS.Palette.purple.opacity(0.35),
                style: StrokeStyle(lineWidth: 1.4, dash: [6, 5]))
            .background(
                DS.Palette.purple.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .aspectRatio(0.68, contentMode: .fit)
    }

    private var canFlip: Bool {
        snapshot.drawsRemaining > 0 && flippingSlot == nil && !isBusy
    }

    private func slotTilt(_ slot: Int) -> Double {
        [-2.4, 1.6, -1.2, 2.2, -1.8, 1.4][slot]
    }

    /// 冷启动还原：会话开始前的结果按日种子映射到卡槽（两台设备布局一致）；
    /// 本会话翻的牌留在用户点的槽位（slotResults 优先），两者数量互补不冲突。
    private func restoredResult(slot: Int) -> CardGameDraw? {
        let preSessionCount = (snapshot.todayDraws?.count ?? 0) - slotResults.count
        guard preSessionCount > 0 else { return nil }
        let order = cardGameSeededOrder(day: snapshot.day)
        guard let index = order.firstIndex(of: slot), index < preSessionCount else { return nil }
        return snapshot.todayDraws?[index]
    }

    @MainActor
    private func flip(slot: Int) {
        guard canFlip else { return }
        Haptics.light()
        flippingSlot = slot
        onReveal(onFlip) { result in
            if let result { slotResults[slot] = result }
            flippingSlot = nil
        }
    }

}

/// 未翻中的软色调卡面："差一点" + 虚线粉框。
struct CardMissFace: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "heart.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(DS.Palette.pink.opacity(0.55))
            Text("差一点")
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(0.68, contentMode: .fit)
        .background(DS.Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    DS.Palette.pink.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }
    }
}

/// 日种子洗牌：冷启动把已翻结果映射到卡槽，两台设备布局一致。
func cardGameSeededOrder(day: String) -> [Int] {
    var slots = Array(0..<6)
    var seed = day.unicodeScalars.reduce(UInt64(88)) { ($0 &* 31) &+ UInt64($1.value) }
    for index in stride(from: 5, to: 0, by: -1) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let swap = Int(seed % UInt64(index + 1))
        slots.swapAt(index, swap)
    }
    return slots
}
