import SwiftUI

struct CardGameSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: CardGameInventoryItem
    let definition: CardGameDefinition
    let effects: [CardGameEffect]
    let partnerInventory: [CardGameInventoryItem]
    let catalog: [CardGameDefinition]
    let currentUsername: String
    let onUse: (String?, CardGameInventoryItem?) -> Void

    @State private var selectedEffectID: String?
    @State private var selectedSourceID: String?

    private var needsTarget: Bool { definition.modifier != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CardFaceView(definition: definition, quantity: item.quantity)
                        .frame(maxWidth: 190)
                        .padding(.top, 6)

                    if definition.modifier == "copy" {
                        sourcePicker
                    } else if needsTarget {
                        effectPicker
                    }

                    Button {
                        Haptics.medium()
                        let source = partnerInventory.first { $0.id == selectedSourceID }
                        onUse(selectedEffectID, source)
                    } label: {
                        Text("使用这张卡")
                            .font(DS.Typo.button)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(item.rarity.tint, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(useDisabled)
                    .opacity(useDisabled ? 0.55 : 1)
                }
                .padding(DS.Spacing.page)
                .frame(maxWidth: .infinity)
            }
            .background(AppPageBackground())
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var sheetTitle: String {
        switch definition.modifier {
        case "copy": return "选择要复制的卡"
        case "qiankun": return "选择要转移的效果"
        case "addTime", "postpone": return "选择要作用的效果"
        default: return "使用卡片"
        }
    }

    private var useDisabled: Bool {
        if definition.modifier == "copy" { return selectedSourceID == nil }
        if needsTarget { return selectedEffectID == nil }
        return false
    }

    private var effectPicker: some View {
        // 乾坤只能转移对你生效的；加时/延期只能作用在你自己打出的效果上，
        // 与服务端校验一致，避免选完才报错。
        let availableEffects: [CardGameEffect]
        switch definition.modifier {
        case "qiankun":
            availableEffects = effects.filter { $0.targetUsername == currentUsername }
        case "addTime", "postpone":
            availableEffects = effects.filter { $0.senderUsername == currentUsername && $0.expiresAt != nil }
        default:
            availableEffects = effects
        }
        return VStack(alignment: .leading, spacing: 9) {
            Text(definition.modifier == "qiankun" ? "正在对你生效的效果" : "你打出的倒计时效果")
                .font(DS.Typo.cardTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if availableEffects.isEmpty {
                Text(definition.modifier == "qiankun"
                    ? "目前没有可以转移的对方效果"
                    : "目前没有你自己打出的倒计时效果")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(availableEffects) { effect in
                    selectionRow(
                        title: effect.title,
                        detail: effect.summary,
                        selected: selectedEffectID == effect.id,
                        tint: effect.rarity.tint) {
                            selectedEffectID = effect.id
                        }
                }
            }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("对方卡库")
                .font(DS.Typo.cardTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if partnerInventory.isEmpty {
                Text("对方卡库暂时为空")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(partnerInventory) { source in
                    selectionRow(
                        title: sourceTitle(source),
                        detail: "库存 ×\(source.quantity)",
                        selected: selectedSourceID == source.id,
                        tint: source.rarity.tint) {
                            selectedSourceID = source.id
                        }
                }
            }
        }
    }

    private func selectionRow(
        title: String,
        detail: String,
        selected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? tint : DS.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DS.Typo.secondary.weight(.semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(detail)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
            }
            .padding(13)
            .background(selected ? tint.opacity(0.10) : DS.Palette.cardSurface, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .stroke(selected ? tint.opacity(0.35) : DS.Palette.hairline, lineWidth: 0.8)
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func sourceTitle(_ source: CardGameInventoryItem) -> String {
        let title = catalog.first {
            $0.key == source.cardKey && $0.rarity == source.rarity
        }?.title ?? source.cardKey
        return "\(title) · \(source.rarity.title)"
    }
}

/// 抽卡揭示：卡背先落场，点一下才翻面。翻面瞬间按稀有度爆发光芒，
/// 史诗以上追加粒子。翻转用双面渲染：前 90° 显示卡背，后 90° 显示卡面。
struct CardRevealOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var angle: Double = 0
    @State private var showRays = false
    @State private var burst = false
    let card: CardGameDefinition
    let onClose: () -> Void

    private var flipped: Bool { angle >= 90 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.56).ignoresSafeArea()
                .onTapGesture { if flipped { onClose() } }

            if showRays {
                rays
            }

            VStack(spacing: 22) {
                Text(flipped ? "\(card.rarity.title)卡！" : "点一下翻开")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white.opacity(flipped ? 1 : 0.85))
                    .contentTransition(.opacity)

                ZStack {
                    CardBackView()
                        .opacity(flipped ? 0 : 1)
                    CardFaceView(definition: card)
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                        .opacity(flipped ? 1 : 0)
                }
                .frame(maxWidth: 230)
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.62)
                .scaleEffect(entered ? 1 : 0.66)
                .offset(y: entered ? 0 : -46)
                .onTapGesture { flip() }

                VStack(spacing: 12) {
                    Text(card.summary)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button("收下") { onClose() }
                        .font(DS.Typo.button)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 30)
                        .frame(minHeight: 46)
                        .background(card.rarity.tint, in: Capsule())
                        .buttonStyle(PressableStyle())
                }
                .opacity(flipped ? 1 : 0)
            }
            .padding(26)
        }
        .onAppear {
            if reduceMotion {
                entered = true
                angle = 180
                burst = true
                return
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                entered = true
            }
        }
    }

    private func flip() {
        guard !flipped else { return }
        Haptics.medium()
        if reduceMotion {
            angle = 180
            return
        }
        withAnimation(.spring(response: 0.58, dampingFraction: 0.74)) {
            angle = 180
        }
        // 先以收拢状态插入光芒层，下一拍再动画展开+淡出，保证起始帧可见。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showRays = true
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 1.05)) { burst = true }
            }
            if card.rarity == .legendary || card.rarity == .epic {
                Haptics.medium()
            }
        }
    }

    private var rays: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(card.rarity.tint.opacity(0.55))
                    .frame(width: 5, height: burst ? 128 : 26)
                    .offset(y: burst ? -150 : -52)
                    .rotationEffect(.degrees(Double(index) / 12 * 360))
            }
            if card.rarity == .legendary || card.rarity == .epic {
                ForEach(0..<14, id: \.self) { index in
                    Image(systemName: "sparkle")
                        .font(.system(size: CGFloat(8 + index % 3 * 4)))
                        .foregroundStyle(card.rarity.tint)
                        .offset(
                            x: CGFloat((index * 53) % 200 - 100) * (burst ? 1.5 : 0.3),
                            y: CGFloat((index * 37) % 170 - 85) * (burst ? 1.6 : 0.3))
                }
            }
        }
        .opacity(burst ? 0 : 0.95)
        .allowsHitTesting(false)
    }
}

extension CardGameRarity {
    var tint: Color {
        switch self {
        case .common: return Color(red: 0.18, green: 0.67, blue: 0.38)
        case .rare: return Color(red: 0.22, green: 0.48, blue: 0.92)
        case .epic: return Color(red: 0.58, green: 0.33, blue: 0.88)
        case .legendary: return Color(red: 0.94, green: 0.60, blue: 0.12)
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .common:
            return LinearGradient(colors: [Color.green.opacity(0.10), DS.Palette.cardSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .rare:
            return LinearGradient(colors: [Color.blue.opacity(0.13), DS.Palette.cardSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .epic:
            return LinearGradient(colors: [Color.purple.opacity(0.16), DS.Palette.cardSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .legendary:
            return LinearGradient(colors: [Color.yellow.opacity(0.24), DS.Palette.cardSurface, Color.orange.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
