import SwiftUI

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

/// 居中全屏翻牌浮层：卡背升场 → 多圈旋转 → 空中光色绽放揭晓稀有度 →
/// 揭面 + 分级光芒。史诗以上停留等点击，其余自动收尾。全屏渲染不受
/// 牌阵面板裁剪。
struct CardFlipRevealOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let perform: () async -> CardGameDraw?
    let onFinish: (CardGameDraw?) -> Void

    @State private var draw: CardGameDraw?
    @State private var charging = true
    @State private var entered = false
    @State private var spinAngle: Double = 0
    @State private var bloomed = false
    @State private var burstFired = false
    @State private var finished = false

    private var tier: CardFlipTier {
        CardFlipTier(rarity: draw?.card?.rarity ?? (draw?.success == true ? .common : nil))
    }
    private var revealed: Bool { spinAngle >= 810 }

    var body: some View {
        ZStack {
            Color.black.opacity(entered ? 0.58 : 0).ignoresSafeArea()

            ForEach(0..<tier.rayCount, id: \.self) { index in
                Capsule()
                    .fill(tier.color.opacity(0.6))
                    .frame(width: tier == .legendary ? 6 : 4.5, height: burstFired ? tier.rayLength : 24)
                    .offset(y: burstFired ? -tier.rayLength : -60)
                    .rotationEffect(.degrees(Double(index) / Double(max(1, tier.rayCount)) * 360))
                    .opacity(revealed && !burstFired ? 0.9 : (burstFired ? 0 : 0))
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [(bloomed ? tier.color : .white).opacity(0.55), .clear],
                        center: .center, startRadius: 6, endRadius: 210))
                .frame(width: 420, height: 420)
                .opacity(entered && !finished ? 1 : 0)

            VStack(spacing: 18) {
                ZStack {
                    if spinAngle < 810 {
                        CardBackView()
                            .scaleEffect(charging ? 1.04 : 1)
                            .animation(
                                charging
                                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                    : .easeOut(duration: 0.2),
                                value: charging)
                    } else if let card = draw?.card {
                        CardFaceView(definition: card)
                            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                    } else {
                        CardMissFace()
                            .background(DS.Palette.cardSurface)
                            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                    }
                }
                .frame(maxWidth: 220)
                .rotation3DEffect(.degrees(spinAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .scaleEffect(entered ? 1 : 0.5)
                .shadow(color: tier.color.opacity(revealed ? 0.6 : 0.2), radius: 26)

                VStack(spacing: 8) {
                    Text(resultTitle)
                        .font(.title3.weight(.black))
                        .foregroundStyle(.white)
                        .shadow(color: tier.color, radius: 10)
                    if let summary = draw?.card?.summary {
                        Text(summary)
                            .font(DS.Typo.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    if tier.showsShowcase {
                        Text("点一下收进卡库")
                            .font(DS.Typo.micro)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .opacity(revealed ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if revealed { finish(draw) } }
        .onAppear { run() }
    }

    private var resultTitle: String {
        guard let card = draw?.card else { return "差一点，再翻一张" }
        return "\(card.rarity.title)卡 · \(card.title)"
    }

    private func run() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) { entered = true }
        let appearedAt = Date()
        Task { @MainActor in
            let result = await perform()
            // 至少让充能停留 0.45s，快网络下也有蓄力感。
            let elapsed = Date().timeIntervalSince(appearedAt)
            if elapsed < 0.45 {
                try? await Task.sleep(nanoseconds: UInt64((0.45 - elapsed) * 1_000_000_000))
            }
            guard let result else {
                withAnimation(.easeIn(duration: 0.24)) { entered = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { finish(nil) }
                return
            }
            draw = result
            charging = false
            startSpin(result)
        }
    }

    private func startSpin(_ result: CardGameDraw) {
        if reduceMotion {
            spinAngle = 900
            bloomed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { finish(result) }
            return
        }
        withAnimation(.easeInOut(duration: 1.05)) { spinAngle = 900 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeOut(duration: 0.28)) { bloomed = true }
            if tier >= .epic { Haptics.medium() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.07) {
            Haptics.medium()
            withAnimation(.easeOut(duration: tier == .legendary ? 1.15 : 0.8)) { burstFired = true }
            if !tier.showsShowcase {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { finish(result) }
            }
        }
    }

    private func finish(_ result: CardGameDraw?) {
        guard !finished else { return }
        finished = true
        onFinish(result)
    }
}
