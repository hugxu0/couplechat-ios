import XCTest
import UIKit
@testable import CoupleChat

final class ChatMarkdownRendererTests: XCTestCase {
    func testMultilineBubbleUsesWidestLogicalLineInsteadOfConstraintWidth() {
        let compact = try! XCTUnwrap(ChatMessage(dict: [
            "id": "ai-multiline", "channel": "ai", "sender": "ai", "senderName": "大橘",
            "kind": "ai", "type": "text", "text": "喵，早上好。\n\n今天有什么安排吗？", "ts": 1,
        ]))
        let longSingleLine = try! XCTUnwrap(ChatMessage(dict: [
            "id": "ai-long", "channel": "ai", "sender": "ai", "senderName": "大橘",
            "kind": "ai", "type": "text", "text": String(repeating: "很长的一句话", count: 20), "ts": 2,
        ]))

        XCTAssertLessThan(ChatTimelineMetrics.textBubbleWidth(for: compact, containerWidth: 390), 250)
        XCTAssertGreaterThan(ChatTimelineMetrics.textBubbleWidth(for: longSingleLine, containerWidth: 390), 270)
    }
    func testRendererRemovesMarkdownMarkersAndPreservesContent() {
        let rendered = ChatMarkdownRenderer.attributedString(
            from: "## 标题\n- **重要**事项\n> 引用\n`code`")

        XCTAssertFalse(rendered.string.contains("##"))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertTrue(rendered.string.contains("标题"))
        XCTAssertTrue(rendered.string.contains("•  重要事项"))
        XCTAssertTrue(rendered.string.contains("┃ 引用"))
        XCTAssertTrue(rendered.string.contains("code"))
    }

    func testRendererRecognizesMarkdownTableSeparator() {
        let rendered = ChatMarkdownRenderer.attributedString(
            from: "| 日期 | 心情 |\n| --- | --- |\n| 7/12 | 开心 |")

        XCTAssertFalse(rendered.string.contains("---"))
        XCTAssertFalse(rendered.string.contains("|"))
        XCTAssertTrue(rendered.string.contains("日期：7/12"))
        XCTAssertTrue(rendered.string.contains("心情：开心"))
    }

    func testRendererPreservesProseDashesAndOrderedListMarkers() {
        let rendered = ChatMarkdownRenderer.attributedString(
            from: "今天—明天都可以，选项 A｜B\n\n5. 第五项\n6) 第六项")

        XCTAssertTrue(rendered.string.contains("今天—明天都可以，选项 A｜B"))
        XCTAssertTrue(rendered.string.contains("5. 第五项"))
        XCTAssertTrue(rendered.string.contains("6. 第六项"))
    }

    func testRendererSupportsEscapedPipesInsideTableCells() {
        let rendered = ChatMarkdownRenderer.attributedString(
            from: "| 项目 | 内容 |\n| --- | --- |\n| 选择 | A \\| B |")

        XCTAssertTrue(rendered.string.contains("内容：A | B"))
    }

    func testRendererReusesCachedStructuredMessageForTheSameStyle() {
        let markdown = "| 日期 | 心情 |\n| --- | --- |\n| 7/12 | **开心** |"
        let first = ChatMarkdownRenderer.attributedString(
            from: markdown,
            textColor: .label,
            accentColor: .systemMint)
        let second = ChatMarkdownRenderer.attributedString(
            from: markdown,
            textColor: .label,
            accentColor: .systemMint)

        XCTAssertTrue(first === second)
    }

    func testRendererCacheKeepsAccentStylesIndependent() {
        let markdown = "| 日期 | 心情 |\n| --- | --- |\n| 7/12 | 开心 |"
        let red = ChatMarkdownRenderer.attributedString(from: markdown, accentColor: .systemRed)
        let blue = ChatMarkdownRenderer.attributedString(from: markdown, accentColor: .systemBlue)
        let redHeader = red.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let blueHeader = blue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor

        XCTAssertTrue(redHeader?.isEqual(UIColor.systemRed) == true)
        XCTAssertTrue(blueHeader?.isEqual(UIColor.systemBlue) == true)
    }

    func testRendererKeepsIncompleteMermaidAsPlainText() {
        let rendered = ChatMarkdownRenderer.attributedString(from: "mermaid")

        XCTAssertEqual(rendered.string, "mermaid")
    }

    func testRendererAddsLinkAttribute() throws {
        let rendered = ChatMarkdownRenderer.attributedString(
            from: "查看 [官网](https://example.com/path)")
        let location = try XCTUnwrap(rendered.string.range(of: "官网"))
        let index = rendered.string.distance(from: rendered.string.startIndex, to: location.lowerBound)
        let link = rendered.attribute(.link, at: index, effectiveRange: nil) as? String

        XCTAssertEqual(link, "https://example.com/path")
    }

    func testConfirmationContainsFullMemoAndScope() {
        let confirm = message(meta: [
            "confirm": [
                "status": "pending",
                "items": [[
                    "label": "备忘：黄金走势",
                    "action": [
                        "type": "add_memo",
                        "title": "黄金走势",
                        "text": "| 日期 | 收盘价 |\n| --- | --- |\n| 7/11 | 4121 |",
                        "scope": "personal",
                    ],
                ]],
                "requesterName": "小旭",
                "requesterUsername": "xu",
            ],
        ]).meta!.confirm!

        let markdown = ChatTimelineMetrics.confirmationMarkdown(confirm)
        XCTAssertTrue(markdown.contains("范围：私人"))
        XCTAssertTrue(markdown.contains("7/11 | 4121"))
    }

    func testMermaidFlowchartRendersAsDiagramInsteadOfSourceCode() {
        let rendered = ChatMarkdownRenderer.attributedString(from: """
        ```mermaid
        flowchart TD
          A[开始] --> B{是否确认}
          B -->|是| C[执行]
          B -->|否| D[取消]
        ```
        """)

        XCTAssertFalse(rendered.string.contains("flowchart TD"))
        XCTAssertTrue(rendered.string.contains("开始"))
        XCTAssertTrue(rendered.string.contains("是否确认"))
        XCTAssertTrue(rendered.string.contains("执行"))
        XCTAssertTrue(rendered.string.contains("取消"))
        XCTAssertTrue(rendered.string.contains("▼"))
    }

    func testSharedParserAcceptsLooseMermaidBlocksAndKeepsAllNodeText() {
        let markdown = """
        mermaid
        flowchart TD
          A[准备西红柿、鸡蛋、葱蒜和调料] --> B[鸡蛋打散]

        做完就可以开吃。
        """
        let blocks = MarkdownBlock.parse(markdown)

        XCTAssertEqual(blocks.count, 2)
        guard case .mermaid(let source) = blocks[0] else {
            return XCTFail("第一块应识别为 Mermaid")
        }
        let diagram = MermaidFlowchartFormatter.render(source)
        XCTAssertTrue(diagram?.contains("准备西红柿、鸡蛋、葱蒜和调料") == true)
        XCTAssertTrue(diagram?.contains("鸡蛋打散") == true)
        XCTAssertEqual(blocks[1], .paragraph("做完就可以开吃。"))
    }

    func testConfirmationAddsHeightAndUsesFullBubbleWidth() {
        let plain = message(meta: nil)
        let confirmed = message(meta: [
            "confirm": [
                "status": "pending",
                "items": [["label": "备忘：日常小确幸记录表", "action": ["type": "add_memo", "text": "内容"]]],
                "requesterName": "小旭",
                "requesterUsername": "xu",
            ],
        ])

        XCTAssertGreaterThan(
            ChatTimelineMetrics.messageHeight(for: confirmed, containerWidth: 390, groupedWithPrevious: false),
            ChatTimelineMetrics.messageHeight(for: plain, containerWidth: 390, groupedWithPrevious: false))
        XCTAssertGreaterThan(
            ChatTimelineMetrics.textBubbleWidth(for: confirmed, containerWidth: 390),
            ChatTimelineMetrics.textBubbleWidth(for: plain, containerWidth: 390))
    }

    private func message(meta: [String: Any]?) -> ChatMessage {
        var value: [String: Any] = [
            "id": UUID().uuidString,
            "sender": "ai",
            "senderName": "大橘",
            "kind": "ai",
            "type": "text",
            "text": "请确认",
            "channel": "ai:xu",
            "ts": 1_000,
        ]
        value["meta"] = meta
        return ChatMessage(dict: value)!
    }
}
