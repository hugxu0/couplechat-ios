import SwiftUI

struct RecommendationHistoryRow: View {
    let item: RecommendationItem

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.gap) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sourceTitle)
                        .font(DS.Typo.sectionLabel)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer(minLength: 8)
                    Text(timestamp)
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                Text(item.content)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        item.isFromDaju ? AccountPresentation.dajuIconName : "gift.fill"
    }

    private var tint: Color {
        item.isFromDaju ? DS.Palette.orange : item.isMine ? DS.Palette.accent : DS.Palette.pink
    }

    private var sourceTitle: String {
        if item.isFromDaju { return "大橘" }
        return item.isMine ? "你推荐给 TA" : "\(item.sourceName) 推荐给你"
    }

    private var timestamp: String {
        Date(timeIntervalSince1970: Double(item.createdAt) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
