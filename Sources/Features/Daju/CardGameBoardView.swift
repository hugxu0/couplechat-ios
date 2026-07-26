import SwiftUI

/// 每日翻牌阵：五张背面卡手撒排开（3+2、微倾角、待机浮动），点一张翻一张。
/// 翻牌序列：充能发光（掩盖网络请求）→ 升起多圈旋转 → 空中光色绽放揭晓
/// 稀有度 → 落回卡槽 → 分级爆发。已翻结果由服务端快照还原，跨设备一致。
struct CardGameBoardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: CardGameSnapshot
    let isBusy: Bool
    let onFlip: () async -> CardGameDraw?
    let onShowcase: (CardGameDefinition) -> Void

    @State private var slotResults: [Int: CardGameDraw] = [:]
    @State private var flippingSlot: Int?
    @State private var phase: FlipPhase = .idle
    @State private var spinAngle: Double = 0
    @State private var auraBloom = false
    @State private var burstTier: CardFlipTier?
    @State private var burstSlot: Int?
    @State private var burstFired = false

    private enum FlipPhase { case idle, charging, airborne, landing }

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
            Text("\(snapshot.drawsUsed) / 5")
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
                ForEach(0..<5, id: \.self) { slot in
                    slotCard(slot: slot, width: cardWidth)
                        .position(positions[slot])
                }
                if let tier = burstTier, let burstSlot {
                    CardFlipBurstLayer(tier: tier, center: positions[burstSlot], fired: burstFired)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 330)
    }

    private func slotPositions(in size: CGSize, cardWidth: CGFloat, cardHeight: CGFloat) -> [CGPoint] {
        let gapX = cardWidth + 14
        let topY = cardHeight / 2 + 12
        let bottomY = topY + cardHeight + 18
        let centerX = size.width / 2
        return [
            CGPoint(x: centerX - gapX, y: topY),
            CGPoint(x: centerX, y: topY),
            CGPoint(x: centerX + gapX, y: topY),
            CGPoint(x: centerX - gapX / 2, y: bottomY),
            CGPoint(x: centerX + gapX / 2, y: bottomY),
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
                flippingCard(slot: slot, width: width)
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
                Task { await flip(slot: slot) }
            } label: {
                CardBackView()
                    .rotationEffect(.degrees(slotTilt(slot)))
                    .offset(y: bob)
                    .opacity(flippable ? 1 : 0.5)
            }
            .buttonStyle(PressableStyle())
            .disabled(!flippable)
        }
    }

    private func flippingCard(slot: Int, width: CGFloat) -> some View {
        let result = slotResults[slot]
        let tier = CardFlipTier(rarity: result?.card?.rarity ?? (result?.success == true ? .common : nil))
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (auraBloom ? tier.color : Color.white).opacity(phase == .charging ? 0.5 : 0.75),
                            .clear,
                        ],
                        center: .center, startRadius: 4, endRadius: width * 1.25))
                .frame(width: width * 2.6, height: width * 2.6)
                .opacity(phase == .idle ? 0 : 1)

            flipSides(result: result)
                .rotation3DEffect(.degrees(spinAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .scaleEffect(phase == .airborne ? 1.55 : (phase == .charging ? 1.06 : 1))
                .offset(y: phase == .airborne ? -46 : 0)
        }
        .zIndex(2)
    }

    @ViewBuilder
    private func flipSides(result: CardGameDraw?) -> some View {
        // 810° 是侧棱视角，在这一帧换面不穿帮；卡面预转 180° 抵消最终朝向。
        if spinAngle < 810 {
            CardBackView()
        } else if let card = result?.card {
            CardFaceView(definition: card, compact: true)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        } else {
            CardMissFace()
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
    }

    private var canFlip: Bool {
        snapshot.drawsRemaining > 0 && flippingSlot == nil && !isBusy
    }

    private func slotTilt(_ slot: Int) -> Double {
        [-2.4, 1.6, -1.2, 2.2, -1.8][slot]
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
    private func flip(slot: Int) async {
        guard canFlip else { return }
        Haptics.light()
        flippingSlot = slot
        phase = .charging
        spinAngle = 0
        auraBloom = false

        let result = await onFlip()
        guard let result else {
            // 请求失败：卡片落回原位，错误横幅由外层展示。
            withAnimation(DS.Anim.ease) { phase = .idle }
            flippingSlot = nil
            return
        }
        slotResults[slot] = result

        if reduceMotion {
            spinAngle = 900
            phase = .landing
            finishFlip(slot: slot, result: result)
            return
        }

        withAnimation(.easeIn(duration: 0.32)) { phase = .airborne }
        withAnimation(.easeInOut(duration: 1.05).delay(0.1)) { spinAngle = 900 }
        // 空中过半时光色绽放——稀有度在这一刻揭晓。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(.easeOut(duration: 0.3)) { auraBloom = true }
            let tier = CardFlipTier(rarity: result.card?.rarity)
            if tier >= .epic { Haptics.medium() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.68)) { phase = .landing }
            finishFlip(slot: slot, result: result)
        }
    }

    @MainActor
    private func finishFlip(slot: Int, result: CardGameDraw) {
        let tier = CardFlipTier(rarity: result.card?.rarity ?? (result.success ? .common : nil))
        Haptics.medium()
        fireBurst(tier: tier, slot: slot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            flippingSlot = nil
            phase = .idle
            spinAngle = 0
            auraBloom = false
            if tier.showsShowcase, let card = result.card {
                onShowcase(card)
            }
        }
    }

    private func fireBurst(tier: CardFlipTier, slot: Int) {
        burstTier = tier
        burstSlot = slot
        burstFired = false
        // 先以收拢状态插入，下一拍再展开+淡出，保证起始帧可见。
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: tier == .legendary ? 1.2 : 0.85)) { burstFired = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            burstTier = nil
            burstSlot = nil
            burstFired = false
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
        .background(DS.Palette.fieldSurface.opacity(0.8))
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
    var slots = Array(0..<5)
    var seed = day.unicodeScalars.reduce(UInt64(88)) { ($0 &* 31) &+ UInt64($1.value) }
    for index in stride(from: 4, to: 0, by: -1) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let swap = Int(seed % UInt64(index + 1))
        slots.swapAt(index, swap)
    }
    return slots
}
