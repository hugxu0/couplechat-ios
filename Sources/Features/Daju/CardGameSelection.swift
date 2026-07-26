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
