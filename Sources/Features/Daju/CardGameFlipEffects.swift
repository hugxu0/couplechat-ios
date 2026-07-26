import SwiftUI

/// 翻中后的分级爆发：未中/普通小光环，稀有蓝环，史诗紫色光柱+粒子，
/// 传说全屏金闪+光束雨+冲击波。铺在牌阵上层，坐标以触发卡槽为中心。
struct CardFlipBurstLayer: View {
    let tier: CardFlipTier
    let center: CGPoint
    let fired: Bool

    var body: some View {
        ZStack {
            if tier >= .epic {
                Rectangle()
                    .fill(tier.color)
                    .opacity(fired ? 0 : (tier == .legendary ? 0.42 : 0.22))
                    .ignoresSafeArea()
            }

            ForEach(0..<tier.rayCount, id: \.self) { index in
                Capsule()
                    .fill(tier.color.opacity(0.65))
                    .frame(width: tier == .legendary ? 6 : 4.5, height: fired ? tier.rayLength : 20)
                    .offset(y: fired ? -tier.rayLength * 0.92 : -34)
                    .rotationEffect(.degrees(Double(index) / Double(max(1, tier.rayCount)) * 360))
                    .position(center)
            }

            ForEach(0..<tier.ringCount, id: \.self) { index in
                Circle()
                    .stroke(tier.color.opacity(0.55 - Double(index) * 0.12), lineWidth: 3.5 - CGFloat(index))
                    .frame(width: 60, height: 60)
                    .scaleEffect(fired ? 3.4 + CGFloat(index) * 1.3 : 0.4)
                    .position(center)
            }

            ForEach(0..<tier.sparkleCount, id: \.self) { index in
                Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "star.fill")
                    .font(.system(size: CGFloat(8 + index % 4 * 4)))
                    .foregroundStyle(tier.color)
                    .position(
                        x: center.x + CGFloat((index * 61) % 240 - 120) * (fired ? 1.7 : 0.25),
                        y: center.y + CGFloat((index * 43) % 200 - 100) * (fired ? 1.8 : 0.25))
                    .rotationEffect(.degrees(Double(index * 37 % 360)))
            }
        }
        .opacity(fired ? 0 : 1)
        .allowsHitTesting(false)
    }
}

/// 史诗/传说的居中大卡展示（money shot）：光束旋转 + 星雨，点击提前收起。
struct CardShowcaseOverlay: View {
    let definition: CardGameDefinition
    let onDismiss: () -> Void

    @State private var entered = false

    private var tier: CardFlipTier { CardFlipTier(rarity: definition.rarity) }

    var body: some View {
        ZStack {
            Color.black.opacity(entered ? 0.6 : 0).ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 7) / 7
                ZStack {
                    ForEach(0..<10, id: \.self) { index in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [tier.color.opacity(0.5), .clear],
                                    startPoint: .top, endPoint: .bottom))
                            .frame(width: 30, height: 500)
                            .rotationEffect(.degrees(Double(index) * 36 + phase * 360))
                    }
                }
                .opacity(entered ? 0.5 : 0)
            }

            ForEach(0..<16, id: \.self) { index in
                Image(systemName: "sparkle")
                    .font(.system(size: CGFloat(7 + index % 4 * 4)))
                    .foregroundStyle(tier.color.opacity(0.9))
                    .offset(
                        x: CGFloat((index * 67) % 320 - 160),
                        y: entered ? CGFloat((index * 91) % 560 - 240) : -320)
                    .animation(
                        .easeIn(duration: 1.4 + Double(index % 5) * 0.22).delay(Double(index) * 0.05),
                        value: entered)
            }

            VStack(spacing: 20) {
                Text(definition.rarity == .legendary ? "传说降临！" : "史诗现身！")
                    .font(.title2.weight(.black))
                    .foregroundStyle(.white)
                    .shadow(color: tier.color, radius: 12)
                CardFaceView(definition: definition)
                    .frame(maxWidth: 240)
                    .scaleEffect(entered ? 1 : 0.5)
                    .shadow(color: tier.color.opacity(0.7), radius: 30)
                Text("点一下收进卡库")
                    .font(DS.Typo.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .opacity(entered ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { entered = true }
        }
    }
}

/// 演出分级：未中与普通轻量、稀有中等、史诗紫光、传说金光全套。
enum CardFlipTier: Int, Comparable {
    case miss
    case common
    case rare
    case epic
    case legendary

    init(rarity: CardGameRarity?) {
        switch rarity {
        case .none: self = .miss
        case .common: self = .common
        case .rare: self = .rare
        case .epic: self = .epic
        case .legendary: self = .legendary
        }
    }

    static func < (lhs: CardFlipTier, rhs: CardFlipTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: Color {
        switch self {
        case .miss: return DS.Palette.pink.opacity(0.8)
        case .common: return CardGameRarity.common.tint
        case .rare: return CardGameRarity.rare.tint
        case .epic: return CardGameRarity.epic.tint
        case .legendary: return Color(red: 1.0, green: 0.78, blue: 0.25)
        }
    }

    var rayCount: Int {
        switch self {
        case .miss: return 0
        case .common: return 6
        case .rare: return 8
        case .epic: return 12
        case .legendary: return 16
        }
    }

    var rayLength: CGFloat {
        switch self {
        case .miss, .common: return 90
        case .rare: return 120
        case .epic: return 170
        case .legendary: return 230
        }
    }

    var ringCount: Int {
        switch self {
        case .miss, .common: return 1
        case .rare: return 2
        case .epic: return 2
        case .legendary: return 3
        }
    }

    var sparkleCount: Int {
        switch self {
        case .miss: return 5
        case .common: return 7
        case .rare: return 10
        case .epic: return 14
        case .legendary: return 20
        }
    }

    var showsShowcase: Bool { self >= .epic }
}
