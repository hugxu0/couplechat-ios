import SwiftUI

struct PlanMarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            inlineText(text)
                .font(level == 1 ? DS.Typo.pageTitle : (level == 2 ? DS.Typo.cardTitle : DS.Typo.button))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? DS.Spacing.tight : 1)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(DS.Palette.accent)
                        inlineText(item)
                    }
                }
            }
        case .numbers(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(DS.Palette.accent)
                            .fontWeight(.semibold)
                        inlineText(item)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(DS.Palette.accent.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.vertical, 2)
        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.gap - 2)
                .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        case .mermaid(let source):
            Text(MermaidFlowchartFormatter.render(source) ?? source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.gap)
                .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .rule:
            Divider()
                .overlay(DS.Palette.textSecondary.opacity(0.22))
        }
    }

    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { index in
                        tableCell(index < headers.count ? headers[index] : "", header: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            tableCell(
                                columnIndex < row.count ? row[columnIndex] : "",
                                header: false,
                                alternate: rowIndex % 2 == 1
                            )
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ text: String, header: Bool, alternate: Bool = false) -> some View {
        inlineText(text)
            .font(header ? DS.Typo.caption.weight(.semibold) : DS.Typo.caption)
            .foregroundStyle(DS.Palette.textPrimary)
            .frame(minWidth: 92, maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                header
                    ? AnyShapeStyle(DS.Palette.accent.opacity(0.14))
                    : AnyShapeStyle(alternate ? DS.Palette.innerSurface.opacity(0.42) : DS.Palette.cardSurface.opacity(0.35))
            )
            .overlay(Rectangle().stroke(DS.Palette.textSecondary.opacity(0.16), lineWidth: 0.7))
    }
}
