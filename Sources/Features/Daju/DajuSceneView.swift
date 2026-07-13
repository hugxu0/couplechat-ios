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
        HStack(spacing: 10) {
            Label("Lv.\(pet.level)", systemImage: "sparkles")
            ProgressView(value: Double(pet.experience % 100), total: 100)
                .tint(DS.Palette.orange)
                .accessibilityLabel("成长进度")
                .accessibilityValue("百分之\(pet.experience % 100)")
            Text("经验 \(pet.experience % 100)%")
        }
        .font(DS.Typo.caption.weight(.semibold))
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
        .background(DS.Palette.cardSurface.opacity(isNight ? 0.32 : 0.76), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
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
            ProgressView(value: Double(value), total: 100)
                .tint(color)
            Text("\(value)")
                .font(DS.Typo.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isNight ? Color.white.opacity(0.9) : DS.Palette.textPrimary)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
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
        return Button { perform(kind) } label: {
            VStack(spacing: 6) {
                Image(systemName: kind.systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(height: 24)
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
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(DS.Palette.cardSurface.opacity(isNight ? 0.34 : 0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(isNight ? 0.11 : 0.3), lineWidth: 0.7)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy || remaining > 0)
        .opacity(remaining > 0 ? 0.55 : 1)
        .accessibilityHint(remaining > 0 ? "冷却中" : "互动会同步到你们的设备")
    }

    private var chatEntrance: some View {
        Button(action: onChat) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("和大橘聊聊").font(DS.Typo.button)
                    Text("去它的私聊房间").font(DS.Typo.micro).opacity(0.78)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                LinearGradient(
                    colors: [DS.Palette.orange, DS.Palette.pink.opacity(0.88)],
                    startPoint: .leading,
                    endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("打开和大橘的私聊")
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
