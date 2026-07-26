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
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(effect.rarity.tint)
                .font(.body)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(effect.title)
                        .font(DS.Typo.secondary.weight(.semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(effect.rarity.title)
                        .font(DS.Typo.micro.weight(.bold))
                        .foregroundStyle(effect.rarity.tint)
                    Spacer()
                    Text(timeText)
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                directionLine
                Text(effect.summary)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 11)
    }

    /// 出牌方 ➜ 生效方，名字加粗，自己标注“我”并用主题紫色。
    private var directionLine: some View {
        let selfTarget = effect.senderUsername == effect.targetUsername
        return HStack(spacing: 5) {
            nameTag(effect.senderName, isMe: effect.senderUsername == currentUsername)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(effect.rarity.tint)
            if selfTarget {
                Text("自己")
                    .font(DS.Typo.caption.weight(.bold))
                    .foregroundStyle(DS.Palette.textPrimary)
            } else {
                nameTag(effect.targetName, isMe: effect.targetUsername == currentUsername)
            }
        }
    }

    private func nameTag(_ name: String, isMe: Bool) -> some View {
        Text(isMe ? "\(name)（我）" : name)
            .font(DS.Typo.caption.weight(.bold))
            .foregroundStyle(isMe ? DS.Palette.purple : DS.Palette.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                (isMe ? DS.Palette.purple : DS.Palette.textTertiary).opacity(0.10),
                in: Capsule())
    }

    private var timeText: String {
        ChatTimelineBuilder.timeLabel(
            for: Date(timeIntervalSince1970: Double(effect.createdAt) / 1000),
            calendar: .current,
            now: Date())
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
