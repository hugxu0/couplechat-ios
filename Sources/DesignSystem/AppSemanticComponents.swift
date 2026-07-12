import SwiftUI

struct AppPageBackground: View {
    var body: some View {
        Color(.systemGroupedBackground).ignoresSafeArea()
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, DS.Spacing.page)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

extension RootPageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct AppSectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .foregroundStyle(.primary)
    }
}

struct AppCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

private struct AppSurfaceStyle: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

extension View {
    func appSurface(radius: CGFloat = DS.Radius.card) -> some View {
        modifier(AppSurfaceStyle(radius: radius))
    }
}

struct StatusBanner: View {
    enum Kind { case info, success, warning, error }

    let text: String
    var kind: Kind = .info

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
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
