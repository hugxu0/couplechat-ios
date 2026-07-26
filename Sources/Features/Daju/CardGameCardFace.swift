import SwiftUI

/// 真卡牌观感的卡面：外框按稀有度渐变描边，内部分艺术区（图标 + 光晕 +
/// 稀有度宝石）与文字区。传说卡的金光扫过由 TimelineView 驱动——
/// 不依赖 onAppear 状态翻转，LazyVGrid 复用后不会熄灭。
struct CardFaceView: View {
    let definition: CardGameDefinition
    var quantity: Int?
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            artArea
            infoArea
        }
        .background(faceBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(frameGradient, lineWidth: definition.rarity == .legendary ? 2.4 : 1.6)
        }
        .overlay(alignment: .topTrailing) {
            if let quantity, quantity > 1 {
                Text("×\(quantity)")
                    .font(DS.Typo.micro.weight(.heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(definition.rarity.tint, in: Capsule())
                    .padding(6)
            }
        }
        .overlay {
            if definition.rarity == .legendary {
                legendaryShine
            } else if definition.rarity == .epic {
                epicFoil
            }
        }
        .aspectRatio(0.68, contentMode: .fit)
        .shadow(
            color: definition.rarity.tint.opacity(definition.rarity == .legendary ? 0.34 : 0.14),
            radius: definition.rarity == .legendary ? 12 : 7, y: 5)
    }

    private var artArea: some View {
        ZStack {
            RadialGradient(
                colors: [definition.rarity.tint.opacity(0.42), definition.rarity.tint.opacity(0.08)],
                center: .center, startRadius: 4, endRadius: compact ? 62 : 96)
            Image(systemName: definition.icon)
                .font(.system(size: compact ? 30 : 44, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: definition.rarity.tint.opacity(0.6), radius: 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 74 : 116)
        .background(artBackdrop)
        .overlay(alignment: .bottom) {
            rarityGems
                .offset(y: 7)
        }
    }

    private var infoArea: some View {
        VStack(spacing: compact ? 2 : 4) {
            Text(definition.title)
                .font(compact ? DS.Typo.caption.weight(.bold) : DS.Typo.secondary.weight(.bold))
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if !compact {
                Text(definition.summary)
                    .font(DS.Typo.micro)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            durationBadge
        }
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.top, compact ? 10 : 12)
        .padding(.bottom, compact ? 7 : 9)
        // 顶对齐：卡高随网格拉伸时标题贴着艺术区，不悬浮在信息区中央。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let label = durationLabel {
            Text(label)
                .font(DS.Typo.micro.weight(.semibold))
                .foregroundStyle(definition.rarity.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(definition.rarity.tint.opacity(0.12), in: Capsule())
        }
    }

    private var durationLabel: String? {
        if let durationMs = definition.durationMs, definition.effectKind == "timed" {
            return "\(durationMs / 60_000) 分钟"
        }
        switch definition.modifier {
        case "copy": return "复制"
        case "qiankun": return "转移"
        case "addTime": return "加时"
        case "postpone": return "延期"
        default: return definition.effectKind == "instant" ? "即时" : nil
        }
    }

    private var rarityGems: some View {
        HStack(spacing: 3) {
            ForEach(0..<definition.rarity.gemCount, id: \.self) { _ in
                Image(systemName: "diamond.fill")
                    .font(.system(size: compact ? 6 : 8, weight: .black))
                    .foregroundStyle(definition.rarity.tint)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(DS.Palette.cardSurface, in: Capsule())
        .overlay {
            Capsule().strokeBorder(definition.rarity.tint.opacity(0.4), lineWidth: 0.8)
        }
    }

    private var artBackdrop: LinearGradient {
        LinearGradient(
            colors: [
                definition.rarity.tint.opacity(0.88),
                definition.rarity.tint.opacity(0.55),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    private var faceBackground: some View {
        definition.rarity.gradient
    }

    private var frameGradient: LinearGradient {
        LinearGradient(
            colors: [
                definition.rarity.tint.opacity(0.9),
                definition.rarity.tint.opacity(0.35),
                definition.rarity.tint.opacity(0.75),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var epicFoil: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.16), .clear, .white.opacity(0.10), .clear],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        .allowsHitTesting(false)
    }

    private var legendaryShine: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
            AngularGradient(
                colors: [.clear, .white.opacity(0.5), .clear],
                center: .center,
                angle: .degrees(phase * 360))
            .blendMode(.screen)
            .opacity(0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// 卡背：深色底 + 网格纹样 + 中央双心纹章，抽卡翻转前展示。
struct CardBackView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.26, green: 0.16, blue: 0.44),
                    Color(red: 0.14, green: 0.12, blue: 0.32),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            Canvas { canvasContext, size in
                let step: CGFloat = 26
                var row = 0
                var y: CGFloat = 10
                while y < size.height {
                    var x: CGFloat = row.isMultiple(of: 2) ? 10 : 23
                    while x < size.width {
                        canvasContext.draw(
                            Text(Image(systemName: "suit.heart.fill"))
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.07)),
                            at: CGPoint(x: x, y: y))
                        x += step
                    }
                    y += step * 0.8
                    row += 1
                }
            }

            Circle()
                .strokeBorder(.white.opacity(0.32), lineWidth: 1.4)
                .frame(width: 92, height: 92)
            Circle()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .frame(width: 108, height: 108)
            HStack(spacing: -7) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(DS.Palette.pink.opacity(0.92))
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .rotationEffect(.degrees(-8))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.5), .white.opacity(0.14), .white.opacity(0.36)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1.6)
        }
        .aspectRatio(0.68, contentMode: .fit)
        .shadow(color: Color(red: 0.2, green: 0.14, blue: 0.4).opacity(0.4), radius: 14, y: 8)
    }
}

extension CardGameRarity {
    var gemCount: Int {
        switch self {
        case .common: return 1
        case .rare: return 2
        case .epic: return 3
        case .legendary: return 4
        }
    }
}
