import SwiftUI

enum PetDrawerSection: String, CaseIterable, Identifiable {
    case today
    case collection
    case footprints

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天一起"
        case .collection: return "藏品"
        case .footprints: return "足迹"
        }
    }
}

struct PetContentPanel: View {
    let pet: CouplePetState
    let currentUsername: String
    let isBusy: Bool
    let errorMessage: String?
    let usingCachedSnapshot: Bool
    let showsDrawerHandle: Bool
    let onRespond: (String) async -> Bool
    let onPlaceItems: ([String]) -> Void
    let onRefresh: () async -> Void

    @State private var section = PetDrawerSection.today

    var body: some View {
        VStack(spacing: 12) {
            if showsDrawerHandle {
                Capsule()
                    .fill(DS.Palette.textSecondary.opacity(0.24))
                    .frame(width: 42, height: 5)
                    .accessibilityHidden(true)
            }

            Picker("大橘内容", selection: $section) {
                ForEach(PetDrawerSection.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if usingCachedSnapshot {
                StatusBanner(text: "网络暂不可用，正在展示上次同步的小窝", kind: .info)
            }
            if let errorMessage {
                StatusBanner(text: errorMessage, kind: .warning)
            }

            selectedContent
        }
        .padding(DS.Spacing.card)
        .background(DS.Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityLabel("正在同步大橘")
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch section {
        case .today:
            PetTodayTogetherView(
                prompt: pet.today,
                currentUsername: currentUsername,
                isBusy: isBusy,
                onRespond: onRespond)
        case .collection:
            PetCollectionView(
                items: pet.inventory,
                placedItemIds: pet.scene.placedItemIds,
                isBusy: isBusy,
                onPlaceItems: onPlaceItems)
        case .footprints:
            PetFootprintsView(moments: pet.moments)
        }
    }
}
