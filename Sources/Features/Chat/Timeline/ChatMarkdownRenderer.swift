import UIKit

enum ChatMarkdownRenderer {
    static func attributedString(
        from markdown: String,
        baseFont: UIFont = .systemFont(ofSize: 17),
        textColor: UIColor = .label,
        accentColor: UIColor = .systemBlue
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for block in MarkdownBlock.parse(markdown) {
            let rendered: NSAttributedString
            switch block {
            case .paragraph(let text):
                rendered = renderedLine(text, baseFont: baseFont, textColor: textColor, accentColor: accentColor)
            case .heading(let level, let text):
                rendered = renderedLine(
                    String(repeating: "#", count: level) + " " + text,
                    baseFont: baseFont,
                    textColor: textColor,
                    accentColor: accentColor)
            case .bullets(let items):
                rendered = joinedLines(items.map {
                    renderedLine("- " + $0, baseFont: baseFont, textColor: textColor, accentColor: accentColor)
                })
            case .numbers(let items):
                rendered = joinedLines(items.enumerated().map { index, item in
                    renderedLine("\(index + 1). \(item)", baseFont: baseFont, textColor: textColor, accentColor: accentColor)
                })
            case .quote(let text):
                rendered = renderedLine("> " + text, baseFont: baseFont, textColor: textColor, accentColor: accentColor)
            case .code(let code):
                rendered = codeAttributedString(from: code, baseFont: baseFont, textColor: textColor)
            case .mermaid(let source):
                rendered = mermaidAttributedString(
                    from: source,
                    baseFont: baseFont,
                    textColor: textColor,
                    accentColor: accentColor)
            case .table(let headers, let rows):
                rendered = renderedTable(
                    headers: headers,
                    rows: rows,
                    baseFont: baseFont,
                    textColor: textColor,
                    accentColor: accentColor)
            case .rule:
                rendered = NSAttributedString(
                    string: "────────────────",
                    attributes: [.font: baseFont, .foregroundColor: textColor.withAlphaComponent(0.24)])
            }
            if output.length > 0 { output.append(NSAttributedString(string: "\n\n")) }
            output.append(rendered)
        }
        return output
    }

    private static func joinedLines(_ lines: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(line)
        }
        return result
    }

    private static func codeAttributedString(
        from code: String,
        baseFont: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: code,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: max(12, baseFont.pointSize - 1), weight: .regular),
                .foregroundColor: textColor,
                .backgroundColor: textColor.withAlphaComponent(0.08),
            ])
    }

    static func mermaidAttributedString(
        from source: String,
        baseFont: UIFont = .systemFont(ofSize: 17),
        textColor: UIColor = .label,
        accentColor: UIColor = .systemBlue
    ) -> NSAttributedString {
        guard let diagram = MermaidFlowchartFormatter.render(source) else {
            return codeAttributedString(from: source, baseFont: baseFont, textColor: textColor)
        }
        let result = NSMutableAttributedString(
            string: diagram,
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: max(12, baseFont.pointSize - 2), weight: .regular),
                .foregroundColor: textColor,
            ])
        let ns = result.string as NSString
        let arrowExpression = try? NSRegularExpression(pattern: #"[│▼├└→◇┌┐└┘─]"#)
        for match in arrowExpression?.matches(in: result.string, range: NSRange(location: 0, length: ns.length)).reversed() ?? [] {
            result.addAttribute(.foregroundColor, value: accentColor, range: match.range)
        }
        return result
    }

    static func boundingSize(for markdown: String, font: UIFont, width: CGFloat) -> CGSize {
        // 与消息气泡实际使用的 UILabel 走同一套排版，避免富文本中的段落、
        // 粗体、列表和表格被 boundingRect 低估高度后在 cell 底部截断。
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = font
        label.attributedText = attributedString(from: markdown, baseFont: font)
        let fitted = label.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: ceil(min(width, fitted.width)), height: ceil(fitted.height))
    }

    private static func renderedLine(
        _ rawLine: String,
        baseFont: UIFont,
        textColor: UIColor,
        accentColor: UIColor
    ) -> NSAttributedString {
        var line = rawLine
        var font = baseFont
        var prefix = ""

        if let heading = line.range(of: #"^\s{0,3}(#{1,6})\s+"#, options: .regularExpression) {
            let level = line[heading].filter { $0 == "#" }.count
            line.removeSubrange(heading)
            font = .systemFont(
                ofSize: max(baseFont.pointSize, baseFont.pointSize + CGFloat(4 - min(level, 4))),
                weight: .bold)
        } else if let quote = line.range(of: #"^\s{0,3}>\s?"#, options: .regularExpression) {
            line.removeSubrange(quote)
            prefix = "┃ "
            font = .italicSystemFont(ofSize: baseFont.pointSize)
        } else if let task = line.range(of: #"^\s*[-*+]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
            let marker = String(line[task])
            prefix = marker.range(of: #"\[[xX]\]"#, options: .regularExpression) == nil ? "☐ " : "☑ "
            line.removeSubrange(task)
        } else if let bullet = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
            line.removeSubrange(bullet)
            prefix = "•  "
        } else if let ordered = line.range(of: #"^\s*(\d+)[.)]\s+"#, options: .regularExpression) {
            let marker = String(line[ordered]).trimmingCharacters(in: .whitespaces)
            prefix = marker.replacingOccurrences(of: ")", with: ".") + " "
            line.removeSubrange(ordered)
        }

        let result = NSMutableAttributedString(
            string: prefix + line,
            attributes: [.font: font, .foregroundColor: textColor])
        applyInlineMarkdown(to: result, baseFont: font, textColor: textColor, accentColor: accentColor)
        if !prefix.isEmpty {
            result.addAttribute(
                .foregroundColor,
                value: accentColor,
                range: NSRange(location: 0, length: (prefix as NSString).length))
        }
        return result
    }

    private static func renderedTable(
        headers: [String],
        rows: [[String]],
        baseFont: UIFont,
        textColor: UIColor,
        accentColor: UIColor
    ) -> NSAttributedString {
        guard !rows.isEmpty else {
            return NSAttributedString(
                string: headers.joined(separator: " · "),
                attributes: [
                    .font: UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                    .foregroundColor: textColor,
                ])
        }
        let result = NSMutableAttributedString(string: "")
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex > 0 { result.append(NSAttributedString(string: "\n\n")) }
            for column in 0..<max(headers.count, row.count) {
                if column > 0 { result.append(NSAttributedString(string: "\n")) }
                let header = column < headers.count ? headers[column] : "第\(column + 1)列"
                let value = column < row.count ? row[column] : ""
                result.append(NSAttributedString(
                    string: "\(header)：",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: max(13, baseFont.pointSize - 1), weight: .semibold),
                        .foregroundColor: accentColor,
                    ]))
                let renderedValue = NSMutableAttributedString(
                    string: value.isEmpty ? "—" : value,
                    attributes: [.font: baseFont, .foregroundColor: textColor])
                applyInlineMarkdown(
                    to: renderedValue,
                    baseFont: baseFont,
                    textColor: textColor,
                    accentColor: accentColor)
                result.append(renderedValue)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func applyInlineMarkdown(
        to value: NSMutableAttributedString,
        baseFont: UIFont,
        textColor: UIColor,
        accentColor: UIColor
    ) {
        replaceMatches(in: value, pattern: #"\[([^\]]+)\]\(([^\s)]+)\)"#) { match, source in
            NSAttributedString(
                string: source.substring(with: match.range(at: 1)),
                attributes: [
                    .font: baseFont,
                    .foregroundColor: accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: source.substring(with: match.range(at: 2)),
                ])
        }
        replaceDelimited(in: value, pattern: #"`([^`]+)`"#, font: .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular), color: textColor, background: textColor.withAlphaComponent(0.08))
        replaceDelimited(in: value, pattern: #"\*\*([^*]+)\*\*"#, font: .systemFont(ofSize: baseFont.pointSize, weight: .bold), color: textColor)
        replaceDelimited(in: value, pattern: #"__([^_]+)__"#, font: .systemFont(ofSize: baseFont.pointSize, weight: .bold), color: textColor)
        replaceDelimited(in: value, pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#, font: .italicSystemFont(ofSize: baseFont.pointSize), color: textColor)
        replaceDelimited(in: value, pattern: #"~~([^~]+)~~"#, font: baseFont, color: textColor, strikethrough: true)
    }

    private static func replaceDelimited(
        in value: NSMutableAttributedString,
        pattern: String,
        font: UIFont,
        color: UIColor,
        background: UIColor? = nil,
        strikethrough: Bool = false
    ) {
        replaceMatches(in: value, pattern: pattern) { match, source in
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let background { attributes[.backgroundColor] = background }
            if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return NSAttributedString(string: source.substring(with: match.range(at: 1)), attributes: attributes)
        }
    }

    private static func replaceMatches(
        in value: NSMutableAttributedString,
        pattern: String,
        replacement: (NSTextCheckingResult, NSString) -> NSAttributedString
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let source = value.string as NSString
        let matches = expression.matches(in: value.string, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            value.replaceCharacters(in: match.range, with: replacement(match, source))
        }
    }

}
