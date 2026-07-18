import UIKit

enum ChatMarkdownRenderer {
    private final class MarkdownBlocksBox: NSObject {
        let blocks: [MarkdownBlock]

        init(_ blocks: [MarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private final class RenderCacheKey: NSObject {
        let markdown: String
        let font: UIFont
        let textColor: UIColor
        let accentColor: UIColor

        init(markdown: String, font: UIFont, textColor: UIColor, accentColor: UIColor) {
            self.markdown = markdown
            self.font = font
            self.textColor = textColor
            self.accentColor = accentColor
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(markdown)
            hasher.combine(font.hash)
            hasher.combine(textColor.hash)
            hasher.combine(accentColor.hash)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? RenderCacheKey else { return false }
            return markdown == other.markdown
                && font.isEqual(other.font)
                && textColor.isEqual(other.textColor)
                && accentColor.isEqual(other.accentColor)
        }
    }

    private final class LayoutCacheKey: NSObject {
        let markdown: String
        let font: UIFont
        let width: CGFloat

        init(markdown: String, font: UIFont, width: CGFloat) {
            self.markdown = markdown
            self.font = font
            self.width = width
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(markdown)
            hasher.combine(font.hash)
            hasher.combine(width)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? LayoutCacheKey else { return false }
            return markdown == other.markdown
                && font.isEqual(other.font)
                && width == other.width
        }
    }

    private static let blockCache: NSCache<NSString, MarkdownBlocksBox> = {
        let cache = NSCache<NSString, MarkdownBlocksBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()

    private static let renderCache: NSCache<RenderCacheKey, NSAttributedString> = {
        let cache = NSCache<RenderCacheKey, NSAttributedString>()
        cache.countLimit = 384
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    private static let layoutCache: NSCache<LayoutCacheKey, NSValue> = {
        let cache = NSCache<LayoutCacheKey, NSValue>()
        cache.countLimit = 512
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()

    private static let compactWidthCache: NSCache<LayoutCacheKey, NSNumber> = {
        let cache = NSCache<LayoutCacheKey, NSNumber>()
        cache.countLimit = 512
        cache.totalCostLimit = 128 * 1_024
        return cache
    }()

    private static let linkExpression = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^\s)]+)\)"#)
    private static let codeExpression = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let boldAsteriskExpression = try! NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let boldUnderscoreExpression = try! NSRegularExpression(pattern: #"__([^_]+)__"#)
    private static let italicExpression = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#)
    private static let strikethroughExpression = try! NSRegularExpression(pattern: #"~~([^~]+)~~"#)
    private static let mermaidArrowExpression = try! NSRegularExpression(pattern: #"[│▼├└→◇┌┐└┘─]"#)

    static func attributedString(
        from markdown: String,
        baseFont: UIFont = .systemFont(ofSize: 17),
        textColor: UIColor = .label,
        accentColor: UIColor = .systemBlue
    ) -> NSAttributedString {
        let cacheKey = RenderCacheKey(
            markdown: markdown,
            font: baseFont,
            textColor: textColor,
            accentColor: accentColor)
        if let cached = renderCache.object(forKey: cacheKey) { return cached }

        let output = NSMutableAttributedString(string: "")
        for block in parsedBlocks(from: markdown) {
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
                rendered = joinedLines(items.map { item in
                    renderedLine("\(item.marker). \(item.text)", baseFont: baseFont, textColor: textColor, accentColor: accentColor)
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
        let rendered = output.copy() as! NSAttributedString
        renderCache.setObject(rendered, forKey: cacheKey, cost: max(1, rendered.length * 8))
        return rendered
    }

    private static func parsedBlocks(from markdown: String) -> [MarkdownBlock] {
        let key = markdown as NSString
        if let cached = blockCache.object(forKey: key) { return cached.blocks }
        let blocks = MarkdownBlock.parse(markdown)
        blockCache.setObject(
            MarkdownBlocksBox(blocks),
            forKey: key,
            cost: max(1, markdown.utf16.count * 2))
        return blocks
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
        for match in mermaidArrowExpression
            .matches(in: result.string, range: NSRange(location: 0, length: ns.length))
            .reversed() {
            result.addAttribute(.foregroundColor, value: accentColor, range: match.range)
        }
        return result
    }

    static func boundingSize(for markdown: String, font: UIFont, width: CGFloat) -> CGSize {
        let cacheKey = LayoutCacheKey(markdown: markdown, font: font, width: width)
        if let cached = layoutCache.object(forKey: cacheKey) { return cached.cgSizeValue }

        // 与消息气泡实际使用的 UILabel 走同一套排版，避免富文本中的段落、
        // 粗体、列表和表格被 boundingRect 低估高度后在 cell 底部截断。
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.font = font
        label.attributedText = attributedString(from: markdown, baseFont: font)
        let fitted = label.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(min(width, fitted.width)), height: ceil(fitted.height))
        layoutCache.setObject(NSValue(cgSize: size), forKey: cacheKey)
        return size
    }

    static func compactWidth(for markdown: String, font: UIFont, maxWidth: CGFloat) -> CGFloat {
        guard !markdown.isEmpty, maxWidth > 0 else { return 0 }
        let cacheKey = LayoutCacheKey(markdown: markdown, font: font, width: maxWidth)
        if let cached = compactWidthCache.object(forKey: cacheKey) {
            return CGFloat(truncating: cached)
        }

        // 先以允许的最大宽度确定当前行数，再寻找不会增加行数的最窄宽度。
        // 直接裁剪整段自然宽度会让自动换行的短尾行把气泡撑满；按实际 UILabel
        // 高度反向收紧后，两行内容会更均衡，同时不会被继续挤成三行。
        let targetHeight = boundingSize(for: markdown, font: font, width: maxWidth).height
        guard targetHeight > 0 else { return 0 }
        var lowerBound: CGFloat = 1
        var upperBound = maxWidth
        for _ in 0..<10 {
            let candidate = (lowerBound + upperBound) / 2
            let candidateHeight = boundingSize(for: markdown, font: font, width: candidate).height
            if candidateHeight <= targetHeight {
                upperBound = candidate
            } else {
                lowerBound = candidate
            }
        }
        let compactWidth = min(maxWidth, ceil(upperBound))
        compactWidthCache.setObject(NSNumber(value: Double(compactWidth)), forKey: cacheKey)
        return compactWidth
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
        let source = value.string
        if source.contains("[") && source.contains("](") {
            replaceMatches(in: value, expression: linkExpression) { match, matchSource in
                NSAttributedString(
                    string: matchSource.substring(with: match.range(at: 1)),
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: matchSource.substring(with: match.range(at: 2)),
                    ])
            }
        }
        if source.contains("`") {
            replaceDelimited(
                in: value,
                expression: codeExpression,
                font: .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular),
                color: textColor,
                background: textColor.withAlphaComponent(0.08))
        }
        if source.contains("**") {
            replaceDelimited(
                in: value,
                expression: boldAsteriskExpression,
                font: .systemFont(ofSize: baseFont.pointSize, weight: .bold),
                color: textColor)
        }
        if source.contains("__") {
            replaceDelimited(
                in: value,
                expression: boldUnderscoreExpression,
                font: .systemFont(ofSize: baseFont.pointSize, weight: .bold),
                color: textColor)
        }
        if source.contains("*") {
            replaceDelimited(
                in: value,
                expression: italicExpression,
                font: .italicSystemFont(ofSize: baseFont.pointSize),
                color: textColor)
        }
        if source.contains("~~") {
            replaceDelimited(
                in: value,
                expression: strikethroughExpression,
                font: baseFont,
                color: textColor,
                strikethrough: true)
        }
    }

    private static func replaceDelimited(
        in value: NSMutableAttributedString,
        expression: NSRegularExpression,
        font: UIFont,
        color: UIColor,
        background: UIColor? = nil,
        strikethrough: Bool = false
    ) {
        replaceMatches(in: value, expression: expression) { match, source in
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let background { attributes[.backgroundColor] = background }
            if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return NSAttributedString(string: source.substring(with: match.range(at: 1)), attributes: attributes)
        }
    }

    private static func replaceMatches(
        in value: NSMutableAttributedString,
        expression: NSRegularExpression,
        replacement: (NSTextCheckingResult, NSString) -> NSAttributedString
    ) {
        let source = value.string as NSString
        let matches = expression.matches(in: value.string, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            value.replaceCharacters(in: match.range, with: replacement(match, source))
        }
    }

}
