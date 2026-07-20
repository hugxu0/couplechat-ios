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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(definition.title)
                            .font(.title2.weight(.bold))
                        Text(definition.summary)
                            .font(DS.Typo.secondary)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }

                    if definition.modifier == "copy" {
                        sourcePicker
                    } else {
                        effectPicker
                    }

                    Button {
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
                    .disabled(definition.modifier == "copy" ? selectedSourceID == nil : selectedEffectID == nil)
                }
                .padding(DS.Spacing.page)
            }
            .background(AppPageBackground())
            .navigationTitle(definition.modifier == "copy" ? "选择要复制的卡" : "选择要作用的效果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var effectPicker: some View {
        let availableEffects = definition.modifier == "qiankun"
            ? effects.filter { $0.targetUsername == currentUsername }
            : effects
        return VStack(alignment: .leading, spacing: 9) {
            Text(definition.modifier == "qiankun" ? "选择一项正在对你生效的卡片效果" : "选择一项正在生效的卡片效果")
                .font(DS.Typo.cardTitle)
            if availableEffects.isEmpty {
                Text(definition.modifier == "qiankun" ? "目前没有可以转移的对方效果" : "目前没有可以修改的倒计时效果")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 12)
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
            Text("选择对方卡库中的一张卡")
                .font(DS.Typo.cardTitle)
            if partnerInventory.isEmpty {
                Text("对方卡库暂时为空")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 12)
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

struct CardRevealOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flipped = false
    @State private var goldPhase = false
    let card: CardGameDefinition
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("抽到了！")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                VStack(spacing: 13) {
                    Image(systemName: card.icon)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 70, height: 70)
                        .background(card.rarity.tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text(card.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(card.summary)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Text("\(card.rarity.title)卡 · 已存入你的卡库")
                        .font(DS.Typo.caption.weight(.semibold))
                        .foregroundStyle(card.rarity.tint)
                }
                .padding(22)
                .frame(maxWidth: 310)
                .background(card.rarity.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(card.rarity.tint.opacity(card.rarity == .legendary ? 0.75 : 0.35), lineWidth: card.rarity == .legendary ? 2 : 1)
                }
                .overlay {
                    if card.rarity == .legendary {
                        AngularGradient(
                            colors: [.clear, .white.opacity(0.72), .clear],
                            center: .center,
                            angle: .degrees(goldPhase ? 360 : 0))
                            .blendMode(.screen)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }
                .rotation3DEffect(.degrees(flipped ? 0 : 90), axis: (x: 0, y: 1, z: 0))
                .shadow(color: card.rarity.tint.opacity(0.4), radius: 24, y: 12)
                Button("收下") { onClose() }
                    .font(DS.Typo.button)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(minHeight: 46)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .padding(26)
        }
        .onAppear {
            if card.rarity == .legendary, !reduceMotion {
                withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                    goldPhase = true
                }
            }
            if reduceMotion {
                flipped = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.76)) {
                    flipped = true
                }
            }
        }
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
            return LinearGradient(colors: [Color.green.opacity(0.08), DS.Palette.cardSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .rare:
            return LinearGradient(colors: [Color.blue.opacity(0.11), DS.Palette.cardSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .epic:
            return LinearGradient(colors: [Color.purple.opacity(0.13), DS.Palette.cardSurface], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .legendary:
            return LinearGradient(colors: [Color.yellow.opacity(0.22), DS.Palette.cardSurface, Color.orange.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
