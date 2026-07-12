import SwiftUI

struct PetSceneView: View {
    let pet: CouplePetState
    let isBusy: Bool
    let feedback: String?
    let onRename: () -> Void
    let onChat: () -> Void
    let onInteraction: (PetInteractionKind) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isReacting = false

    var body: some View {
        ZStack {
            CachedImage(url: artworkURL) {
                PetRoomBackdrop()
            }
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.10), .clear, .white.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                sceneHeader
                Spacer(minLength: 4)
                feedbackBubble
                catButton
                placedCollectibles
                interactionBar
            }
            .padding(DS.Spacing.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .stroke(.white.opacity(0.45), lineWidth: 0.7)
        }
        .onChange(of: pet.latestInteraction?.id) { _, _ in pulse() }
    }

    private var artworkURL: URL? {
        pet.scene.artworkURL.flatMap { ServerConfig.resolveMediaURL($0) }
    }

    private var sceneHeader: some View {
        HStack(spacing: 8) {
            Label(pet.scene.title, systemImage: "window.vertical.open")
                .font(DS.Typo.sectionLabel)
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button(action: onChat) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("和大橘聊聊")

            Button(action: onRename) {
                Label(pet.name, systemImage: "pencil")
                    .font(DS.Typo.button)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("大橘的名字，当前是 \(pet.name)，轻点改名")
        }
        .foregroundStyle(DS.Palette.textPrimary)
    }

    @ViewBuilder
    private var feedbackBubble: some View {
        if let feedback, !feedback.isEmpty {
            Text(feedback)
                .font(DS.Typo.secondary.weight(.medium))
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(DS.Palette.bubbleOther, in: Capsule())
                .shadow(color: DS.Surface.shadow, radius: 5, y: 2)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            Text(latestActivityText)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var latestActivityText: String {
        guard let activity = pet.latestInteraction else { return "今天也在窗边等你们" }
        return "\(activity.actorName)刚刚\(activity.kind.activityPhrase)"
    }

    private var catButton: some View {
        Button {
            pulse()
            onInteraction(.stroke)
        } label: {
            DajuIllustration(isResponding: isReacting)
                .frame(maxWidth: 230, maxHeight: 245)
                .shadow(color: DS.Palette.orange.opacity(0.18), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("摸摸\(pet.name)")
        .accessibilityHint("互动会同步到你们两个人的设备，不会消耗次数")
    }

    @ViewBuilder
    private var placedCollectibles: some View {
        let placed = pet.inventory.filter { pet.scene.placedItemIds.contains($0.id) }
        if !placed.isEmpty {
            HStack(spacing: 14) {
                ForEach(placed.prefix(4)) { item in
                    Image(systemName: item.symbolName ?? fallbackSymbol(for: item.kind))
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(DS.Palette.orange)
                        .frame(width: 38, height: 34)
                        .background(.ultraThinMaterial, in: RoundedRectangle(
                            cornerRadius: DS.Radius.chip, style: .continuous))
                        .accessibilityLabel("已布置：\(item.name)")
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var interactionBar: some View {
        HStack(spacing: 8) {
            ForEach(PetInteractionKind.allCases) { kind in
                Button {
                    pulse()
                    onInteraction(kind)
                } label: {
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(DS.Typo.sectionLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(
                            cornerRadius: DS.Radius.control, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(isBusy)
                .accessibilityHint("随时可用，没有次数限制")
            }
        }
        .foregroundStyle(DS.Palette.textPrimary)
    }

    private func pulse() {
        guard !reduceMotion else { return }
        withAnimation(DS.Anim.springFast) { isReacting = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            withAnimation(DS.Anim.ease) { isReacting = false }
        }
    }

    private func fallbackSymbol(for kind: String) -> String {
        switch kind {
        case "plant": return "leaf.fill"
        case "photo": return "photo.fill"
        case "music": return "music.note"
        default: return "sparkles"
        }
    }
}
