import Foundation

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbers([String])
    case quote(String)
    case code(String)
    case mermaid(String)
    case table(headers: [String], rows: [[String]])
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                index += 1
                continue
            }
            if let block = fencedBlock(lines, index: &index)
                ?? standaloneBlock(lines, index: &index) {
                result.append(block)
            } else {
                result.append(paragraphBlock(lines, index: &index))
            }
        }
        return result
    }

    private static func fencedBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("```") else { return nil }
        let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
        index += 1
        var content: [String] = []
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            content.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 }
        let first = content.first?.trimmingCharacters(in: .whitespaces).lowercased()
        let isMermaid = language == "mermaid" || (language.isEmpty && first == "mermaid")
        if first == "mermaid" { content.removeFirst() }
        return isMermaid ? .mermaid(content.joined(separator: "\n")) : .code(content.joined(separator: "\n"))
    }

    private static func standaloneBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        if let block = looseMermaidBlock(lines, index: &index) { return block }
        if let block = simpleBlock(lines, index: &index) { return block }
        if let block = tableBlock(lines, index: &index) { return block }
        if let block = listBlock(lines, index: &index) { return block }
        return quoteBlock(lines, index: &index)
    }

    private static func looseMermaidBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.lowercased() == "mermaid", index + 1 < lines.count,
              isMermaidStart(lines[index + 1]) else { return nil }
        index += 1
        var content: [String] = []
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            content.append(lines[index])
            index += 1
        }
        return .mermaid(content.joined(separator: "\n"))
    }

    private static func simpleBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if isRule(line) {
            index += 1
            return .rule
        }
        guard let heading = headingLine(line) else { return nil }
        index += 1
        return .heading(level: heading.level, text: heading.text)
    }

    private static func tableBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        guard index + 1 < lines.count,
              let headers = tableRow(lines[index]),
              isTableSeparator(lines[index + 1]) else { return nil }
        index += 2
        var rows: [[String]] = []
        while index < lines.count, let row = tableRow(lines[index]), !row.isEmpty {
            rows.append(row)
            index += 1
        }
        return .table(headers: headers, rows: rows)
    }

    private static func listBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if let item = bulletLine(line) {
            return .bullets(collectList(lines, index: &index, first: item, parser: bulletLine))
        }
        if let item = numberLine(line) {
            return .numbers(collectList(lines, index: &index, first: item, parser: numberLine))
        }
        return nil
    }

    private static func collectList(
        _ lines: [String],
        index: inout Int,
        first: String,
        parser: (String) -> String?
    ) -> [String] {
        var items = [first]
        index += 1
        while index < lines.count, let item = parser(lines[index].trimmingCharacters(in: .whitespaces)) {
            items.append(item)
            index += 1
        }
        return items
    }

    private static func quoteBlock(_ lines: [String], index: inout Int) -> MarkdownBlock? {
        guard lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") else { return nil }
        var content: [String] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(">") else { break }
            content.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .quote(content.joined(separator: "\n"))
    }

    private static func paragraphBlock(_ lines: [String], index: inout Int) -> MarkdownBlock {
        var content: [String] = []
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard isParagraphLine(line, lines: lines, index: index) else { break }
            content.append(line)
            index += 1
        }
        return .paragraph(content.joined(separator: "\n"))
    }

    private static func isParagraphLine(_ line: String, lines: [String], index: Int) -> Bool {
        guard !line.isEmpty, !line.hasPrefix("```"), line.lowercased() != "mermaid",
              !isRule(line), headingLine(line) == nil, bulletLine(line) == nil,
              numberLine(line) == nil, !line.hasPrefix(">") else { return false }
        return index + 1 >= lines.count || tableRow(line) == nil || !isTableSeparator(lines[index + 1])
    }

    private static func isMermaidStart(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(flowchart|graph)\s+(TD|TB|LR|RL|BT)"#, options: .regularExpression) != nil
    }

    private static func isRule(_ line: String) -> Bool {
        line.range(of: #"^\s*((-{3,})|(\*{3,})|(_{3,}))\s*$"#, options: .regularExpression) != nil
    }

    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6 else { return nil }
        let text = String(line.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes.count, text)
    }

    private static func bulletLine(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberLine(_ line: String) -> String? {
        guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let prefix = line[..<separator]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isNumber }) else { return nil }
        return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func tableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableRow(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return value.filter { $0 == "-" }.count >= 3
                && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}

enum MermaidFlowchartFormatter {
    private struct Node {
        var title: String
        var shape: Character
    }

    private struct Edge {
        var from: String
        var to: String
        var label: String?
    }

    static func render(_ source: String) -> String? {
        let lines = source.components(separatedBy: .newlines)
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.range(of: #"^(flowchart|graph)\s+(TD|TB|LR|RL|BT)"#, options: .regularExpression) != nil else {
            return nil
        }
        var nodes: [String: Node] = [:]
        var edges: [Edge] = []
        let nodePattern = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)\s*([\[\(\{])([^\]\)\}]+)[\]\)\}]"#)
        let edgePattern = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)\s*(?:\[[^\]]*\]|\([^)]*\)|\{[^}]*\})?\s*[-.]+>\s*(?:\|([^|]+)\|\s*)?([A-Za-z0-9_-]+)"#)

        for line in lines.dropFirst() {
            let value = line as NSString
            for match in nodePattern?.matches(in: line, range: NSRange(location: 0, length: value.length)) ?? [] {
                let id = value.substring(with: match.range(at: 1))
                nodes[id] = Node(
                    title: value.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces),
                    shape: Character(value.substring(with: match.range(at: 2))))
            }
            for match in edgePattern?.matches(in: line, range: NSRange(location: 0, length: value.length)) ?? [] {
                let from = value.substring(with: match.range(at: 1))
                let to = value.substring(with: match.range(at: 3))
                let label = match.range(at: 2).location == NSNotFound
                    ? nil
                    : value.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                edges.append(Edge(from: from, to: to, label: label))
                nodes[from] = nodes[from] ?? Node(title: from, shape: "[")
                nodes[to] = nodes[to] ?? Node(title: to, shape: "[")
            }
        }
        guard !edges.isEmpty else { return nil }
        return render(nodes: nodes, edges: edges)
    }

    private static func render(nodes: [String: Node], edges: [Edge]) -> String {
        var children: [String: [Edge]] = [:]
        var incoming = Set<String>()
        for edge in edges {
            children[edge.from, default: []].append(edge)
            incoming.insert(edge.to)
        }
        let roots = nodes.keys.filter { !incoming.contains($0) }.sorted()
        var lines: [String] = []
        var visited = Set<String>()

        func box(_ node: Node) -> [String] {
            let characters = Array(node.title)
            let chunks = stride(from: 0, to: characters.count, by: 18).map {
                String(characters[$0..<min($0 + 18, characters.count)])
            }
            let content = chunks.isEmpty ? [""] : chunks
            let width = max(8, (content.map(\.count).max() ?? 0) + 4)
            let corners = node.shape == "{" ? ("◇", "◇") : ("┌", "┐")
            let lower = node.shape == "{" ? ("◇", "◇") : ("└", "┘")
            var boxLines = [corners.0 + String(repeating: "─", count: width) + corners.1]
            boxLines.append(contentsOf: content.map { line in
                "│  \(line)" + String(repeating: " ", count: width - line.count - 2) + "│"
            })
            boxLines.append(lower.0 + String(repeating: "─", count: width) + lower.1)
            return boxLines
        }

        func draw(_ id: String, prefix: String = "") {
            guard !visited.contains(id), let node = nodes[id] else { return }
            visited.insert(id)
            lines.append(contentsOf: box(node).map { prefix + $0 })
            let next = children[id] ?? []
            if next.count == 1, let edge = next.first {
                lines.append(prefix + "      │")
                lines.append(prefix + "      ▼" + (edge.label.map { "  \($0)" } ?? ""))
                draw(edge.to, prefix: prefix)
            } else {
                for (offset, edge) in next.enumerated() {
                    lines.append(prefix + (offset == next.count - 1 ? "└─ " : "├─ ") + (edge.label ?? "分支") + " →")
                    draw(edge.to, prefix: prefix + "   ")
                }
            }
        }

        for root in roots { draw(root) }
        for id in nodes.keys.sorted() where !visited.contains(id) { draw(id) }
        return lines.joined(separator: "\n")
    }
}
