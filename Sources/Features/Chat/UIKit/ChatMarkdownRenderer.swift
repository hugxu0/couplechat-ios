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
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let fence = rawLine.trimmingCharacters(in: .whitespaces)
                let language = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let line = language == "mermaid"
                    ? mermaidAttributedString(
                        from: codeLines.joined(separator: "\n"),
                        baseFont: baseFont,
                        textColor: textColor,
                        accentColor: accentColor)
                    : codeAttributedString(
                        from: codeLines.joined(separator: "\n"),
                        baseFont: baseFont,
                        textColor: textColor)
                if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
                output.append(line)
                continue
            }
            let line: NSAttributedString
            if index + 1 < lines.count,
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
            index += 1
        }
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
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
        let lines = source.components(separatedBy: .newlines)
        guard let direction = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              direction.range(of: #"^(flowchart|graph)\s+(TD|TB|LR|RL|BT)"#, options: .regularExpression) != nil else {
            return codeAttributedString(from: source, baseFont: baseFont, textColor: textColor)
        }

        struct Node {
            var title: String
            var shape: Character
        }
        struct Edge {
            var from: String
            var to: String
            var label: String?
        }

        var nodes: [String: Node] = [:]
        var edges: [Edge] = []
        let nodePattern = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)\s*([\[\(\{])([^\]\)\}]+)[\]\)\}]"#)
        let edgePattern = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)\s*(?:\[[^\]]*\]|\([^)]*\)|\{[^}]*\})?\s*[-.]+>\s*(?:\|([^|]+)\|\s*)?([A-Za-z0-9_-]+)"#)
        for line in lines.dropFirst() {
            let nsLine = line as NSString
            for match in nodePattern?.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) ?? [] {
                let id = nsLine.substring(with: match.range(at: 1))
                let shape = Character(nsLine.substring(with: match.range(at: 2)))
                let title = nsLine.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                nodes[id] = Node(title: title, shape: shape)
            }
            for match in edgePattern?.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) ?? [] {
                let from = nsLine.substring(with: match.range(at: 1))
                let to = nsLine.substring(with: match.range(at: 3))
                let label = match.range(at: 2).location == NSNotFound
                    ? nil
                    : nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                edges.append(Edge(from: from, to: to, label: label))
                nodes[from] = nodes[from] ?? Node(title: from, shape: "[")
                nodes[to] = nodes[to] ?? Node(title: to, shape: "[")
            }
        }
        guard !edges.isEmpty else { return codeAttributedString(from: source, baseFont: baseFont, textColor: textColor) }

        var children: [String: [Edge]] = [:]
        var incoming = Set<String>()
        for edge in edges {
            children[edge.from, default: []].append(edge)
            incoming.insert(edge.to)
        }
        let roots = nodes.keys.filter { !incoming.contains($0) }.sorted()
        var rendered: [String] = []
        var visited = Set<String>()

        func box(_ node: Node) -> [String] {
            let title = String(node.title.prefix(24))
            let width = max(8, title.count + 2)
            let top = node.shape == "{" ? "◇" + String(repeating: "─", count: width) + "◇" : "┌" + String(repeating: "─", count: width) + "┐"
            let middle = node.shape == "{" ? "│  \(title)  │" : "│  \(title)  │"
            let bottom = node.shape == "{" ? "◇" + String(repeating: "─", count: width) + "◇" : "└" + String(repeating: "─", count: width) + "┘"
            return [top, middle, bottom]
        }

        func draw(_ id: String, prefix: String = "") {
            guard !visited.contains(id), let node = nodes[id] else { return }
            visited.insert(id)
            rendered.append(contentsOf: box(node).map { prefix + $0 })
            let next = children[id] ?? []
            if next.count == 1, let edge = next.first {
                rendered.append(prefix + "      │")
                rendered.append(prefix + "      ▼" + (edge.label.map { "  \($0)" } ?? ""))
                draw(edge.to, prefix: prefix)
            } else if !next.isEmpty {
                for (offset, edge) in next.enumerated() {
                    let branch = offset == next.count - 1 ? "└─" : "├─"
                    rendered.append(prefix + "\(branch) \(edge.label ?? "分支") →")
                    draw(edge.to, prefix: prefix + "   ")
                }
            }
        }

        for root in roots { draw(root) }
        for id in nodes.keys.sorted() where !visited.contains(id) { draw(id) }
        let result = NSMutableAttributedString(
            string: rendered.joined(separator: "\n"),
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
