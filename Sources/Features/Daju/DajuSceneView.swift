import SwiftUI

struct DajuSceneView: View {
    let pet: CouplePetState
    let isBusy: Bool
    let feedback: String?
    let onChat: () -> Void
    let onInteraction: (PetInteractionKind) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var reactionID = UUID()
    @State private var reactionKind = PetInteractionKind.stroke

    private var isNight: Bool {
        colorScheme == .dark || !(6..<19).contains(Calendar.current.component(.hour, from: Date()))
    }

    var body: some View {
        VStack(spacing: 14) {
            modelStage
            growthRow
            needsCard
            interactionBar
            chatEntrance
        }
        .padding(DS.Spacing.card)
        .background(stageBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(.white.opacity(isNight ? 0.16 : 0.5), lineWidth: 0.8)
        }
        .shadow(color: (isNight ? Color.black : DS.Palette.orange).opacity(0.11), radius: 20, y: 9)
    }

    private var modelStage: some View {
        ZStack(alignment: .top) {
            skyDecorations

            Ellipse()
                .fill((isNight ? Color.black : DS.Palette.orange).opacity(0.13))
                .frame(width: 150, height: 25)
                .blur(radius: 7)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)

            DajuModelView(reactionID: reactionID, reaction: reactionKind)
                .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 285)
                .contentShape(Rectangle())
                .onTapGesture { perform(.stroke) }

            feedbackBubble
                .frame(maxWidth: 250)
        }
        .frame(minHeight: 270, maxHeight: 300)
    }

    @ViewBuilder
    private var skyDecorations: some View {
        if isNight {
            Circle()
                .fill(.white.opacity(0.78))
                .frame(width: 48, height: 48)
                .overlay(alignment: .topLeading) {
                    Circle().fill(Color(red: 0.22, green: 0.22, blue: 0.38)).frame(width: 44, height: 44).offset(x: -10, y: -7)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 18)
                .padding(.top, 28)
            ForEach(0..<7, id: \.self) { index in
                Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                    .font(.system(size: index.isMultiple(of: 2) ? 9 : 4))
                    .foregroundStyle(.white.opacity(0.52))
                    .offset(x: CGFloat((index * 47) % 250) - 120, y: CGFloat((index * 31) % 120) + 36)
            }
        } else {
            Circle()
                .fill(Color.yellow.opacity(0.36))
                .frame(width: 72, height: 72)
                .blur(radius: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 8)
                .padding(.top, 24)
            Image(systemName: "heart.fill")
                .foregroundStyle(DS.Palette.pink.opacity(0.38))
                .offset(x: -115, y: 96)
            Image(systemName: "heart.fill")
                .foregroundStyle(DS.Palette.pink.opacity(0.52))
                .offset(x: 116, y: 122)
        }
    }

    private var feedbackBubble: some View {
        Text(feedbackText)
            .font(DS.Typo.secondary.weight(.medium))
            .foregroundStyle(isNight ? Color.white.opacity(0.92) : DS.Palette.textPrimary)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var feedbackText: String {
        if let feedback, !feedback.isEmpty { return feedback }
        guard let activity = pet.latestInteraction else { return "大橘在等你们陪它" }
        return "\(activity.actorName)\(activity.kind.activityPhrase)"
    }

    private var growthRow: some View {
        HStack(spacing: 12) {
            Text("Lv.\(pet.level)")
                .font(DS.Typo.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(DS.Palette.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.Palette.orange.opacity(isNight ? 0.18 : 0.12), in: Capsule())
            petProgress(value: pet.experience % 100, color: DS.Palette.orange)
                .accessibilityLabel("成长进度")
                .accessibilityValue("百分之\(pet.experience % 100)")
            Text("经验 \(pet.experience % 100)%")
                .font(DS.Typo.micro.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(isNight ? Color.white.opacity(0.78) : DS.Palette.textSecondary)
        .padding(.horizontal, 4)
    }

    private var needsCard: some View {
        VStack(spacing: 11) {
            needRow("饱食", symbol: "fork.knife", value: pet.satiety, color: DS.Palette.orange)
            needRow("清洁", symbol: "drop.fill", value: pet.cleanliness, color: DS.Palette.blue)
            needRow("心情", symbol: "heart.fill", value: pet.mood, color: DS.Palette.pink)
            needRow("精力", symbol: "bolt.fill", value: pet.energy, color: DS.Palette.green)
        }
        .padding(14)
        .background(DS.Palette.cardSurface.opacity(isNight ? 0.32 : 0.76), in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                .stroke(.white.opacity(isNight ? 0.12 : 0.32), lineWidth: 0.7)
        }
    }

    private func needRow(_ title: String, symbol: String, value: Int, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(title)
                .font(DS.Typo.caption.weight(.medium))
                .foregroundStyle(isNight ? Color.white.opacity(0.8) : DS.Palette.textSecondary)
                .frame(width: 38, alignment: .leading)
            petProgress(value: value, color: color)
            Text("\(value)")
                .font(DS.Typo.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isNight ? Color.white.opacity(0.9) : DS.Palette.textPrimary)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }

    private func petProgress(value: Int, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(isNight ? Color.white.opacity(0.1) : DS.Palette.textTertiary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(
                        colors: [color.opacity(0.72), color],
                        startPoint: .leading,
                        endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(max(0, min(100, value))) / 100)
            }
        }
        .frame(height: 8)
    }

    private var interactionBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                ForEach(PetInteractionKind.allCases) { kind in
                    interactionButton(kind, now: context.date)
                }
            }
        }
    }

    private func interactionButton(_ kind: PetInteractionKind, now: Date) -> some View {
        let remaining = cooldownRemaining(kind, now: now)
        let color = interactionColor(kind)
        return Button { perform(kind) } label: {
            VStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(isNight ? 0.2 : 0.12), in: Circle())
                Text(kind.title)
                    .font(DS.Typo.sectionLabel)
                    .lineLimit(1)
                Text(kind.cooldownLabel(remaining: remaining))
                    .font(DS.Typo.micro.monospacedDigit())
                    .foregroundStyle(remaining > 0 ? DS.Palette.textTertiary : DS.Palette.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(isNight ? Color.white.opacity(0.9) : DS.Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 94)
            .background(DS.Palette.cardSurface.opacity(isNight ? 0.34 : 0.8), in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .stroke(remaining > 0 ? .white.opacity(isNight ? 0.09 : 0.24) : color.opacity(0.2), lineWidth: 0.8)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy || remaining > 0)
        .opacity(remaining > 0 ? 0.55 : 1)
        .accessibilityHint(remaining > 0 ? "冷却中" : "互动会同步到你们的设备")
    }

    private var chatEntrance: some View {
        Button(action: onChat) {
            HStack(spacing: 13) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(
                        colors: [DS.Palette.orange, DS.Palette.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("和大橘聊聊").font(DS.Typo.button)
                    Text("它会记得只属于你的悄悄话").font(DS.Typo.micro).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .foregroundStyle(isNight ? Color.white.opacity(0.92) : DS.Palette.textPrimary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(DS.Palette.cardSurface.opacity(isNight ? 0.36 : 0.84), in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .stroke(.white.opacity(isNight ? 0.11 : 0.32), lineWidth: 0.8)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("打开和大橘的私聊")
    }

    private func interactionColor(_ kind: PetInteractionKind) -> Color {
        switch kind {
        case .feed: return DS.Palette.orange
        case .bathe: return DS.Palette.blue
        case .play: return DS.Palette.purple
        case .stroke: return DS.Palette.pink
        case .sleep: return Color.indigo
        }
    }

    private func cooldownRemaining(_ kind: PetInteractionKind, now: Date) -> TimeInterval {
        if let cooldown = pet.interactionCooldowns.first(where: { $0.kind == kind }) {
            return max(0, Double(cooldown.availableAt) / 1_000 - now.timeIntervalSince1970)
        }
        guard let latest = pet.latestInteraction, latest.kind == kind else { return 0 }
        let elapsed = now.timeIntervalSince1970 - Double(latest.createdAt) / 1_000
        return max(0, kind.cooldown - elapsed)
    }

    private func perform(_ kind: PetInteractionKind) {
        guard !isBusy, cooldownRemaining(kind, now: Date()) <= 0 else { return }
        reactionKind = kind
        reactionID = UUID()
        if !reduceMotion { Haptics.light() }
        onInteraction(kind)
    }

    private var stageBackground: some View {
        LinearGradient(
            colors: isNight
                ? [Color(red: 0.13, green: 0.14, blue: 0.29), Color(red: 0.24, green: 0.18, blue: 0.31)]
                : [Color(red: 1, green: 0.94, blue: 0.76), Color(red: 0.87, green: 0.97, blue: 0.91)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}
