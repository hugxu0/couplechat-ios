import XCTest
@testable import CoupleChat

final class ChatMarkdownRendererTests: XCTestCase {
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
        XCTAssertTrue(rendered.string.contains("日期  │  心情"))
        XCTAssertTrue(rendered.string.contains("7/12  │  开心"))
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
