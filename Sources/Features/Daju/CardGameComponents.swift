import SwiftUI

struct CardGameEntryCard: View {
    let onOpen: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onOpen()
        } label: {
            ZStack(alignment: .topTrailing) {
                LinearGradient(
                    colors: [DS.Palette.green.opacity(0.88), DS.Palette.blue.opacity(0.86), DS.Palette.purple.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)

                Image(systemName: "suit.heart.fill")
                    .font(.system(size: 92, weight: .black))
                    .foregroundStyle(.white.opacity(0.11))
                    .rotationEffect(.degrees(-18))
                    .offset(x: 15, y: -10)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Label("情侣卡牌", systemImage: "rectangle.stack.fill")
                            .font(DS.Typo.cardTitle)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    Text("每天六张牌，翻中的都会留进卡库")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        badge("绿色 普通")
                        badge("蓝色 稀有")
                        badge("紫色 史诗")
                        badge("金色 传说")
                    }
                    Text("点一张翻一张，出牌后对方进来就能看到效果")
                        .font(DS.Typo.caption)
                        .foregroundStyle(.white.opacity(0.78))
                }
                .foregroundStyle(.white)
                .padding(DS.Spacing.card)
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.8)
            }
            .shadow(color: DS.Palette.blue.opacity(0.16), radius: 16, y: 8)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("打开情侣卡牌游戏")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(DS.Typo.micro)
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.white.opacity(0.13), in: Capsule())
    }
}

struct CardGameEffectRow: View {
    let effect: CardGameEffect
    let now: Date
    let currentUsername: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: effectIcon)
                .font(.body.weight(.bold))
                .foregroundStyle(effect.rarity.tint)
                .frame(width: 38, height: 38)
                .background(effect.rarity.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(effect.title)
                        .font(DS.Typo.button)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(effect.rarity.title)
                        .font(DS.Typo.micro.weight(.bold))
                        .foregroundStyle(effect.rarity.tint)
                }
                Text(relationText)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Text(effect.summary)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if let expiresAt = effect.expiresAt {
                Text(cardGameRemainingText(until: expiresAt, now: now))
                    .font(DS.Typo.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(effect.rarity.tint)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(13)
        .background(DS.Palette.cardSurface, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .stroke(effect.rarity.tint.opacity(0.18), lineWidth: 0.8)
        }
    }

    private var effectIcon: String {
        switch effect.effectKind {
        case "timed": return "timer"
        case "response": return "arrow.triangle.2.circlepath"
        case "modifier": return "wand.and.stars"
        default: return "sparkles"
        }
    }

    private var relationText: String {
        let sentByMe = effect.senderUsername == currentUsername
        let targetsMe = effect.targetUsername == currentUsername
        switch (sentByMe, targetsMe) {
        case (true, true): return "对自己生效 · 你使用"
        case (true, false): return "对方生效 · 你使用"
        case (false, true): return "对你生效 · \(effect.senderName) 使用"
        case (false, false): return "对方对自己生效"
        }
    }
}

struct CardGameHistoryRow: View {
    let effect: CardGameEffect
    let currentUsername: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(effect.rarity.tint)
                .font(.body)
            VStack(alignment: .leading, spacing: 3) {
                Text(effect.title)
                    .font(DS.Typo.secondary.weight(.semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(effect.summary)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(relationText) · \(timeText)")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Text(effect.rarity.title)
                .font(DS.Typo.micro.weight(.bold))
                .foregroundStyle(effect.rarity.tint)
        }
        .padding(.vertical, 11)
    }

    private var timeText: String {
        ChatTimelineBuilder.timeLabel(
            for: Date(timeIntervalSince1970: Double(effect.createdAt) / 1000),
            calendar: .current,
            now: Date())
    }

    private var relationText: String {
        let sentByMe = effect.senderUsername == currentUsername
        let targetsMe = effect.targetUsername == currentUsername
        switch (sentByMe, targetsMe) {
        case (true, true): return "你对自己生效"
        case (true, false): return "你对对方生效"
        case (false, true): return "对你生效 · \(effect.senderName)"
        case (false, false): return "对方对自己生效"
        }
    }
}

private func cardGameRemainingText(until timestamp: Int64, now: Date) -> String {
    let remainingSeconds = max(0, Int((timestamp - Int64(now.timeIntervalSince1970 * 1000)) / 1000))
    let hours = remainingSeconds / 3600
    let minutes = (remainingSeconds % 3600) / 60
    let seconds = remainingSeconds % 60
    if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
    return String(format: "%02d:%02d", minutes, seconds)
}
