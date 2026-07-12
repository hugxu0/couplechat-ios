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
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                let first = codeLines.first?.trimmingCharacters(in: .whitespaces).lowercased()
                if language == "mermaid" || (language.isEmpty && first == "mermaid") {
                    if first == "mermaid" { codeLines.removeFirst() }
                    result.append(.mermaid(codeLines.joined(separator: "\n")))
                } else {
                    result.append(.code(codeLines.joined(separator: "\n")))
                }
                continue
            }
            if line.lowercased() == "mermaid", index + 1 < lines.count,
               isMermaidStart(lines[index + 1]) {
                index += 1
                var mermaidLines: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    mermaidLines.append(lines[index])
                    index += 1
                }
                result.append(.mermaid(mermaidLines.joined(separator: "\n")))
                continue
            }
            if isRule(line) {
                result.append(.rule)
                index += 1
                continue
            }
            if let heading = headingLine(line) {
                result.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            if index + 1 < lines.count,
               let headers = tableRow(line),
               isTableSeparator(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableRow(lines[index]), !row.isEmpty {
                    rows.append(row)
                    index += 1
                }
                result.append(.table(headers: headers, rows: rows))
                continue
            }
            if let item = bulletLine(line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = bulletLine(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                result.append(.bullets(items))
                continue
            }
            if let item = numberLine(line) {
                var items = [item]
                index += 1
                while index < lines.count, let next = numberLine(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                result.append(.numbers(items))
                continue
            }
            if line.hasPrefix(">") {
                var quotes: [String] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    quotes.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                result.append(.quote(quotes.joined(separator: "\n")))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                guard !next.isEmpty,
                      !next.hasPrefix("```"),
                      next.lowercased() != "mermaid",
                      !isRule(next),
                      headingLine(next) == nil,
                      bulletLine(next) == nil,
                      numberLine(next) == nil,
                      !next.hasPrefix(">") else { break }
                if index + 1 < lines.count, tableRow(next) != nil, isTableSeparator(lines[index + 1]) { break }
                paragraph.append(next)
                index += 1
            }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return result
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
