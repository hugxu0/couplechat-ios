import SwiftUI

struct PetCollectionView: View {
    let items: [PetCollectible]
    let placedItemIds: [String]
    let isBusy: Bool
    let onPlaceItems: ([String]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(
                title: "小窝藏品",
                subtitle: "来自共同回应、计划和时光，不使用通用金币")
            if items.isEmpty {
                AppEmptyState(
                    "第一件藏品正在路上",
                    systemImage: "shippingbox",
                    detail: "完成一次“今天一起”就会留下有内容的纪念")
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        collectibleCard(item)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func collectibleCard(_ item: PetCollectible) -> some View {
        let isPlaced = placedItemIds.contains(item.id)
        let placementLimitReached = !isPlaced && placedItemIds.count >= 4
        return Button {
            onPlaceItems(toggledPlacement(for: item.id))
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: item.symbolName ?? fallbackSymbol(item.kind))
                        .font(.title2.weight(.medium))
                        .foregroundStyle(DS.Palette.orange)
                    Spacer()
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .font(DS.Typo.caption.monospacedDigit())
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    Image(systemName: isPlaced ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isPlaced ? DS.Palette.green : DS.Palette.textSecondary)
                }
                Text(item.name)
                    .font(DS.Typo.button)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                Text(isPlaced ? "已在窗边" : "放进小窝")
                    .font(DS.Typo.caption)
                    .foregroundStyle(isPlaced ? DS.Palette.green : DS.Palette.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background(isPlaced ? DS.Palette.orange.opacity(0.10) : DS.Palette.innerSurface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .stroke(isPlaced ? DS.Palette.orange.opacity(0.35) : DS.Palette.hairline)
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy || placementLimitReached)
        .accessibilityLabel("\(item.name)，\(isPlaced ? "已布置" : "未布置")")
        .accessibilityHint(placementHint(isPlaced: isPlaced, limitReached: placementLimitReached))
    }

    private func toggledPlacement(for id: String) -> [String] {
        if placedItemIds.contains(id) {
            return placedItemIds.filter { $0 != id }
        }
        return placedItemIds + [id]
    }

    private func placementHint(isPlaced: Bool, limitReached: Bool) -> String {
        if isPlaced { return "轻点从小窝收起" }
        return limitReached ? "窗边现在最多摆放四件藏品" : "轻点布置到窗边小窝"
    }

    private func fallbackSymbol(_ kind: String) -> String {
        switch kind {
        case "plant": return "leaf.fill"
        case "photo": return "photo.fill"
        case "music": return "music.note"
        case "plan": return "checkmark.seal.fill"
        default: return "sparkles"
        }
    }
}

struct PetFootprintsView: View {
    let moments: [PetMoment]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeader(
                title: "共同足迹",
                subtitle: "这里只有发生过的事情，没有连续打卡压力")
            if moments.isEmpty {
                AppEmptyState(
                    "小窝还很安静",
                    systemImage: "pawprint",
                    detail: "你们完成的共同回应会从服务端同步到这里")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(moments) { moment in
                        footprintCard(moment)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func footprintCard(_ moment: PetMoment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Palette.orange)
                .frame(width: 34, height: 34)
                .background(DS.Palette.orange.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(moment.title)
                        .font(DS.Typo.button)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text(dateText(moment.createdAt))
                        .font(DS.Typo.caption.monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Text(moment.detail)
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(DS.Palette.innerSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func dateText(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(.dateTime.month().day())
    }
}
