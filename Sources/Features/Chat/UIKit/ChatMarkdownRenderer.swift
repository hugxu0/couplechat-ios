import UIKit

enum ChatMarkdownRenderer {
    static func attributedString(
        from markdown: String,
        baseFont: UIFont = .systemFont(ofSize: 17),
        textColor: UIColor = .label,
        accentColor: UIColor = .systemBlue
    ) -> NSAttributedString {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let output = NSMutableAttributedString(string: "")
        let lines = normalized.components(separatedBy: "\n")
        var inCodeBlock = false
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            var advancedPastBlock = false
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                index += 1
                continue
            }
            let line: NSAttributedString
            if inCodeBlock {
                line = NSAttributedString(
                    string: rawLine,
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
                        .foregroundColor: textColor,
                        .backgroundColor: textColor.withAlphaComponent(0.08),
                    ])
            } else if index + 1 < lines.count,
                      tableCells(rawLine).count > 1,
                      isTableSeparator(lines[index + 1]) {
                let headers = tableCells(rawLine)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("|"), candidate.hasSuffix("|") else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                advancedPastBlock = true
                line = renderedTable(
                    headers: headers,
                    rows: rows,
                    baseFont: baseFont,
                    textColor: textColor,
                    accentColor: accentColor)
            } else if isTableSeparator(rawLine) {
                index += 1
                continue
            } else {
                line = renderedLine(rawLine, baseFont: baseFont, textColor: textColor, accentColor: accentColor)
            }
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(line)
            if !advancedPastBlock { index += 1 }
        }
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    static func boundingSize(for markdown: String, font: UIFont, width: CGFloat) -> CGSize {
        attributedString(from: markdown, baseFont: font).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil).integral.size
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

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        return cells.count > 1 && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }
}
