import Foundation

enum MemoDisplayFormatter {
    static func body(for item: PersonalItem) -> String {
        guard item.kind == .memo else { return item.bodyMarkdown }
        var lines = item.bodyMarkdown.components(separatedBy: .newlines)
        trimLeadingBlanks(&lines)
        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           first.hasPrefix("# "), normalized(first.dropFirst(2)) == normalized(item.title) {
            lines.removeFirst()
        }
        trimLeadingBlanks(&lines)
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           isDuplicateDateLine(first, item: item) {
            lines.removeFirst()
        }
        trimLeadingBlanks(&lines)
        return lines.joined(separator: "\n")
    }

    private static func trimLeadingBlanks(_ lines: inout [String]) {
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
    }

    private static func normalized<S: StringProtocol>(_ value: S) -> String {
        String(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isDuplicateDateLine(_ line: String, item: PersonalItem) -> Bool {
        let dates = [item.createdAt, item.updatedAt].map { Date(timeIntervalSince1970: Double($0) / 1000) }
        return dates.contains { date in
            ["yyyy年M月d日", "yyyy-MM-dd", "yyyy/MM/dd"].contains { format in
                let formatter = DateFormatter()
                formatter.dateFormat = format
                let value = formatter.string(from: date)
                return line == value || line == "创建于 \(value)" || line == "更新于 \(value)" || line == "日期：\(value)"
            }
        }
    }
}
