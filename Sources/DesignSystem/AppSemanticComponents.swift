import SwiftUI

struct AppPageBackground: View {
    var body: some View {
        DS.Palette.bgGradient.ignoresSafeArea()
    }
}

struct RootPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    private let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typo.pageTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Spacing.compact)
            trailing
        }
        .padding(.horizontal, DS.Spacing.page)
        .padding(.top, 10)
        .padding(.bottom, DS.Spacing.compact)
        .accessibilityElement(children: .combine)
    }
}

extension RootPageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// 分区小标题（卡片列表上方）
struct AppSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DS.Typo.cardTitle)
                .foregroundStyle(DS.Palette.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 标准内容卡容器：统一内边距 + soft surface
struct AppCard<Content: View>: View {
    var radius: CGFloat = DS.Radius.card
    var padding: CGFloat = DS.Spacing.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(radius: radius)
    }
}

struct StatusBanner: View {
    enum Kind { case info, success, warning, error }

    let text: String
    var kind: Kind = .info

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
            Text(text)
                .font(DS.Typo.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, DS.Spacing.gap)
        .padding(.vertical, 10)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: return DS.Palette.accent
        case .success: return DS.Palette.green
        case .warning: return DS.Palette.orange
        case .error: return DS.Palette.red
        }
    }
}

struct AppEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String?

    init(_ title: String, systemImage: String, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: detail.map { Text($0) })
            .foregroundStyle(DS.Palette.textSecondary)
    }
}

/// 主操作按钮（登录「进入」、表单提交等）
struct AppPrimaryButton: View {
    let title: String
    var busy: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(DS.Typo.button)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.controlVertical)
            .background(DS.Palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .opacity(enabled && !busy ? 1 : 0.5)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled || busy)
    }
}

struct DestructiveActionRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PairedEchoIndicator: View {
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(DS.Palette.blue).frame(width: 6, height: 6)
            Circle().fill(DS.Palette.pink).frame(width: 6, height: 6)
        }
        .accessibilityHidden(true)
    }
}
