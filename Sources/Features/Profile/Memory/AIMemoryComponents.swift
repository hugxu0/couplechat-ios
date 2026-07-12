import SwiftUI

extension AIMemoryLayer {
    var icon: String {
        switch self {
        case .fact: return "checkmark.seal"
        case .event: return "sparkles.rectangle.stack"
        case .plan: return "calendar.badge.clock"
        case .state: return "waveform.path.ecg"
        case .relationship: return "person.2"
        case .insight: return "lightbulb"
        }
    }

    var tint: Color {
        switch self {
        case .fact: return DS.Palette.blue
        case .event: return DS.Palette.pink
        case .plan: return DS.Palette.orange
        case .state: return DS.Palette.green
        case .relationship: return DS.Palette.purple
        case .insight: return DS.Palette.accent
        }
    }
}

struct AIMemoryOverviewCard: View {
    let stats: AIMemoryStats
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AIMemoryOrbitMark()
                VStack(alignment: .leading, spacing: 3) {
                    Text("大橘的记忆")
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(isRefreshing ? "正在整理最近的对话…" : "共同经历与只属于你的悄悄话")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 0) {
                metric("全部", value: stats.total)
                Divider().frame(height: 30)
                metric("共同", value: stats.shared)
                Divider().frame(height: 30)
                metric("我的", value: stats.privateCount)
            }
        }
        .padding(.vertical, 8)
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(DS.Typo.displayNumber.monospacedDigit())
                .foregroundStyle(DS.Palette.textPrimary)
            Text(title)
                .font(DS.Typo.micro)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) 条")
    }
}

private struct AIMemoryOrbitMark: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Palette.blue.opacity(0.45), lineWidth: 1.5)
                .frame(width: 46, height: 30)
                .rotationEffect(.degrees(-24))
            Circle()
                .stroke(DS.Palette.pink.opacity(0.45), lineWidth: 1.5)
                .frame(width: 46, height: 30)
                .rotationEffect(.degrees(24))
            Image(systemName: "pawprint.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Palette.orange)
                .padding(10)
                .background(DS.Palette.orange.opacity(0.12), in: Circle())
        }
        .frame(width: 58, height: 58)
        .accessibilityHidden(true)
    }
}

struct AIMemoryLayerChip: View {
    let layer: AIMemoryLayer?
    let isSelected: Bool
    let action: () -> Void

    private var title: String { layer?.title ?? "全部分类" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let layer { Image(systemName: layer.icon) }
                Text(title)
            }
            .font(DS.Typo.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : DS.Palette.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(isSelected ? DS.Palette.accent : DS.Palette.innerSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AIMemoryRow: View {
    let item: AIMemoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.layer.icon)
                .font(DS.Typo.button)
                .foregroundStyle(item.layer.tint)
                .frame(width: 34, height: 34)
                .background(item.layer.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.content)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(3)
                HStack(spacing: 7) {
                    Label(item.isShared ? "共同" : "我的", systemImage: item.isShared ? "person.2.fill" : "person.fill")
                    Text(item.layer.title)
                    if item.evidenceCount > 0 { Text("来自 \(item.evidenceCount) 条对话") }
                }
                .font(DS.Typo.micro)
                .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct AIMemoryEmptyState: View {
    let hasFilter: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasFilter ? "magnifyingglass" : "pawprint")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(DS.Palette.orange)
            Text(hasFilter ? "没有符合条件的记忆" : "大橘还没记住什么")
                .font(DS.Typo.button)
                .foregroundStyle(DS.Palette.textPrimary)
            Text(hasFilter ? "换个分类或关键词试试。" : "在聊天里自然聊聊，整理后记忆会出现在这里。")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
