import SwiftUI

struct PetSceneView: View {
    let pet: CouplePetState
    let isBusy: Bool
    let feedback: String?
    let onRename: () -> Void
    let onChat: () -> Void
    let onInteraction: (PetInteractionKind) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reactionID = UUID()
    @State private var reactionKind = PetInteractionKind.stroke

    var body: some View {
        VStack(spacing: 14) {
            modelStage
            statusStrip
            interactionBar
        }
        .padding(DS.Spacing.card)
        .background(stageBackground)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.42), lineWidth: 0.8)
        }
        .shadow(color: DS.Palette.orange.opacity(0.08), radius: 22, y: 9)
    }

    private var modelStage: some View {
        ZStack(alignment: .top) {
            Ellipse()
                .fill(DS.Palette.orange.opacity(0.14))
                .frame(width: 210, height: 38)
                .blur(radius: 9)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)

            CuteCatModelView(reactionID: reactionID, reaction: reactionKind)
                .frame(maxWidth: .infinity, minHeight: 285, maxHeight: 360)
                .contentShape(Rectangle())
                .onTapGesture { perform(.stroke) }

            HStack {
                feedbackBubble
                Spacer(minLength: 8)
                Button(action: onChat) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .frame(width: 40, height: 40)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("和大橘聊聊")
                Button(action: onRename) {
                    Image(systemName: "pencil")
                        .frame(width: 40, height: 40)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("给大橘改名")
            }
            .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    @ViewBuilder
    private var feedbackBubble: some View {
        Text(feedbackText)
            .font(DS.Typo.secondary.weight(.medium))
            .foregroundStyle(DS.Palette.textPrimary)
            .lineLimit(2)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var feedbackText: String {
        if let feedback, !feedback.isEmpty { return feedback }
        guard let activity = pet.latestInteraction else { return "在等你们陪它玩" }
        return "\(activity.actorName)\(activity.kind.activityPhrase)"
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            Label("Lv.\(pet.level)", systemImage: "sparkles")
            ProgressView(value: Double(pet.experience % 100), total: 100)
                .tint(DS.Palette.orange)
                .accessibilityLabel("成长进度")
                .accessibilityValue("百分之\(pet.experience % 100)")
            Label("心情 \(pet.mood)", systemImage: "heart.fill")
                .foregroundStyle(DS.Palette.pink)
        }
        .font(DS.Typo.caption.weight(.semibold))
        .foregroundStyle(DS.Palette.textSecondary)
        .padding(.horizontal, 12)
    }

    private var interactionBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 9) {
                ForEach(PetInteractionKind.allCases) { kind in
                    interactionButton(kind, now: context.date)
                }
            }
        }
    }

    private func interactionButton(_ kind: PetInteractionKind, now: Date) -> some View {
        let remaining = cooldownRemaining(kind, now: now)
        return Button { perform(kind) } label: {
            VStack(spacing: 7) {
                Image(systemName: kind.systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(height: 24)
                Text(kind.title)
                    .font(DS.Typo.sectionLabel)
                Text(kind.cooldownLabel(remaining: remaining))
                    .font(DS.Typo.micro.monospacedDigit())
                    .foregroundStyle(remaining > 0 ? DS.Palette.textTertiary : DS.Palette.orange)
            }
            .foregroundStyle(DS.Palette.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(DS.Palette.cardSurface.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 0.7)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy || remaining > 0)
        .opacity(remaining > 0 ? 0.58 : 1)
        .accessibilityHint(remaining > 0 ? "冷却中" : "互动会同步到你们的设备")
    }

    private func cooldownRemaining(_ kind: PetInteractionKind, now: Date) -> TimeInterval {
        if let cooldown = pet.interactionCooldowns.first(where: { $0.kind == kind }) {
            return max(0, Double(cooldown.availableAt) / 1_000 - now.timeIntervalSince1970)
        }
        // 兼容尚未升级的服务端快照。
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
        ZStack {
            LinearGradient(
                colors: [
                    DS.Palette.orange.opacity(0.16),
                    DS.Palette.pink.opacity(0.08),
                    DS.Palette.blue.opacity(0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)
            RadialGradient(
                colors: [.white.opacity(0.38), .clear],
                center: .top,
                startRadius: 10,
                endRadius: 260)
        }
    }
}
