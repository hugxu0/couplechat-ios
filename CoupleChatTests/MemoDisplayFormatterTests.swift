import XCTest
@testable import CoupleChat

final class MemoDisplayFormatterTests: XCTestCase {
    func testRemovesOnlyMatchingLeadingTitleAndDate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let timestamp = Int(formatter.date(from: "2026-07-11")!.timeIntervalSince1970 * 1000)
        let item = PersonalItem(
            id: "memo-1", owner: "xu", kind: .memo, scope: "shared", title: "旅行清单",
            bodyMarkdown: "# 旅行清单\n2026-07-11\n\n| 地点 | 状态 |\n| --- | --- |\n| 海边 | 想去 |",
            dueAt: nil, isDone: false, createdAt: timestamp, updatedAt: timestamp)
        let body = MemoDisplayFormatter.body(for: item)
        XCTAssertFalse(body.contains("# 旅行清单"))
        XCTAssertFalse(body.contains("2026-07-11"))
        XCTAssertTrue(body.contains("| 地点 | 状态 |"))
    }

    func testKeepsDifferentHeading() {
        let item = PersonalItem(
            id: "memo-2", owner: "si", kind: .memo, scope: "personal", title: "旅行",
            bodyMarkdown: "# 行李\n- 充电器", dueAt: nil, isDone: false,
            createdAt: 1_783_699_200_000, updatedAt: 1_783_699_200_000)
        XCTAssertTrue(MemoDisplayFormatter.body(for: item).hasPrefix("# 行李"))
    }
}
