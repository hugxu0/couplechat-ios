import SwiftUI

/// 卡面 v2：全彩饱和底 + 分类暗纹 + 双层卡框与四角纹饰 + 星级。
/// 传说金光扫过与史诗流光由 TimelineView 驱动，LazyVGrid 复用不会熄灭。
struct CardFaceView: View {
    let definition: CardGameDefinition
    var quantity: Int?
    var compact = false

    private var tint: Color { definition.rarity.tint }

    var body: some View {
        ZStack {
            baseLayers
            VStack(spacing: 0) {
                artArea
                titlePlate
                infoArea
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { frameLayers }
        .overlay(alignment: .topTrailing) { quantityBadge }
        .overlay {
            if definition.rarity == .legendary {
                CardSheenLayer(period: 2.6, colors: [.clear, .white.opacity(0.55), .clear], angular: true)
            } else if definition.rarity == .epic {
                CardSheenLayer(period: 3.4, colors: [.clear, .white.opacity(0.30), .clear], angular: false)
            }
        }
        .aspectRatio(0.68, contentMode: .fit)
        .shadow(
            color: tint.opacity(definition.rarity == .legendary ? 0.4 : 0.2),
            radius: definition.rarity == .legendary ? 13 : 8, y: 5)
    }

    private var baseLayers: some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.96), tint.opacity(0.68), tint.opacity(0.88)],
                startPoint: .top, endPoint: .bottom)
            CategoryPatternLayer(category: definition.category.rawValue, compact: compact)
                .opacity(0.16)
            LinearGradient(
                colors: [.white.opacity(0.14), .clear, .black.opacity(0.16)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var artArea: some View {
        ZStack {
            RadialGradient(
                colors: [.white.opacity(0.5), .white.opacity(0.06)],
                center: .center, startRadius: 2, endRadius: compact ? 46 : 74)
            Image(systemName: definition.icon)
                .font(.system(size: compact ? 30 : 46, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                .shadow(color: .white.opacity(0.6), radius: compact ? 8 : 13)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 66 : 108)
        .padding(.top, compact ? 8 : 12)
    }

    private var titlePlate: some View {
        VStack(spacing: compact ? 2 : 3) {
            Text(definition.title)
                .font(compact ? DS.Typo.caption.weight(.heavy) : DS.Typo.secondary.weight(.heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .padding(.vertical, compact ? 3 : 4)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.22))
            starRow
        }
        .padding(.top, compact ? 4 : 6)
    }

    private var starRow: some View {
        HStack(spacing: compact ? 1.5 : 2.5) {
            ForEach(0..<definition.rarity.starCount, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: compact ? 7 : 10, weight: .black))
                    .foregroundStyle(Color(red: 1.0, green: 0.88, blue: 0.35))
                    .shadow(color: .black.opacity(0.3), radius: 0.8, y: 0.6)
            }
        }
    }

    private var infoArea: some View {
        VStack(spacing: compact ? 3 : 5) {
            if !compact {
                Text(definition.summary)
                    .font(DS.Typo.micro)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }
            if let label = durationLabel {
                Text(label)
                    .font(DS.Typo.micro.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(.white.opacity(0.92), in: Capsule())
            }
        }
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.top, compact ? 3 : 6)
        .padding(.bottom, compact ? 8 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var frameLayers: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.9), tint.opacity(0.5), .white.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: definition.rarity == .legendary ? 2.6 : 1.8)
            RoundedRectangle(cornerRadius: 12.5, style: .continuous)
                .strokeBorder(.white.opacity(0.35), lineWidth: 0.8)
                .padding(3.5)
            CardCornerOrnaments(compact: compact)
                .stroke(.white.opacity(0.75), lineWidth: compact ? 1 : 1.3)
                .padding(compact ? 6 : 7)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var quantityBadge: some View {
        if let quantity, quantity > 1 {
            Text("×\(quantity)")
                .font(DS.Typo.micro.weight(.heavy).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.95), in: Capsule())
                .padding(7)
        }
    }
}

/// 四角 L 形纹饰，手绘卡框的点睛处。
struct CardCornerOrnaments: Shape {
    var compact = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arm: CGFloat = compact ? 7 : 10
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (origin, dx, dy) in corners {
            path.move(to: CGPoint(x: origin.x + dx * arm, y: origin.y))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + dy * arm))
        }
        return path
    }
}

/// 分类专属暗纹：亲密心纹、红包钱纹、情绪信纹、选择星纹、辅助魔杖纹。
struct CategoryPatternLayer: View {
    let category: String
    var compact = false

    private var symbol: String {
        switch category {
        case "intimacy": return "heart.fill"
        case "money": return "yensign.circle.fill"
        case "emotion": return "envelope.fill"
        case "choice": return "checkmark.seal.fill"
        default: return "wand.and.stars"
        }
    }

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = compact ? 22 : 30
            var row = 0
            var y: CGFloat = 8
            while y < size.height + step {
                var x: CGFloat = row.isMultiple(of: 2) ? 8 : 8 + step / 2
                while x < size.width + step {
                    context.draw(
                        Text(Image(systemName: symbol))
                            .font(.system(size: compact ? 8 : 11))
                            .foregroundStyle(.white),
                        at: CGPoint(x: x, y: y))
                    x += step
                }
                y += step * 0.82
                row += 1
            }
        }
    }
}

/// 流光层：传说用旋转金光，史诗用斜向扫光；相位取自时钟，复用安全。
struct CardSheenLayer: View {
    let period: Double
    let colors: [Color]
    let angular: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            Group {
                if angular {
                    AngularGradient(colors: colors, center: .center, angle: .degrees(phase * 360))
                        .blendMode(.screen)
                        .opacity(0.55)
                } else {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .offset(x: (phase * 2 - 1) * 180)
                        .blendMode(.screen)
                        .opacity(0.6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// 卡背 v2：金边深紫底、心形暗纹、双环纹章、慢速待机流光。
struct CardBackView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.18, blue: 0.50),
                    Color(red: 0.15, green: 0.12, blue: 0.36),
                    Color(red: 0.24, green: 0.14, blue: 0.44),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            CategoryPatternLayer(category: "intimacy", compact: true)
                .opacity(0.08)

            Circle()
                .strokeBorder(.white.opacity(0.34), lineWidth: 1.4)
                .frame(width: 86, height: 86)
            Circle()
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                .frame(width: 102, height: 102)
            HStack(spacing: -7) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(DS.Palette.pink.opacity(0.95))
                Image(systemName: "heart.fill")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .rotationEffect(.degrees(-8))
            .shadow(color: DS.Palette.pink.opacity(0.5), radius: 9)

            CardSheenLayer(period: 4.6, colors: [.clear, .white.opacity(0.16), .clear], angular: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.86, blue: 0.55).opacity(0.85),
                                Color(red: 0.75, green: 0.58, blue: 0.95).opacity(0.6),
                                Color(red: 1.0, green: 0.86, blue: 0.55).opacity(0.7),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.8)
                CardCornerOrnaments(compact: true)
                    .stroke(Color(red: 1.0, green: 0.86, blue: 0.55).opacity(0.7), lineWidth: 1.1)
                    .padding(6)
            }
        }
        .aspectRatio(0.68, contentMode: .fit)
        .shadow(color: Color(red: 0.2, green: 0.12, blue: 0.4).opacity(0.45), radius: 12, y: 7)
    }
}

extension CardGameRarity {
    var starCount: Int {
        switch self {
        case .common: return 1
        case .rare: return 2
        case .epic: return 3
        case .legendary: return 4
        }
    }
}
