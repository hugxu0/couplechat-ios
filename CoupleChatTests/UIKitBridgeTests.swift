import XCTest
@testable import CoupleChat

final class AccountPresentationTests: XCTestCase {

    func testAvatarForXu() {
        XCTAssertEqual(AccountPresentation.avatar(for: "xu"), "🐶")
    }

    func testAvatarForSi() {
        XCTAssertEqual(AccountPresentation.avatar(for: "si"), "🐰")
    }

    func testAvatarForUnknown() {
        XCTAssertEqual(AccountPresentation.avatar(for: "alice"), "💗")
    }

    func testAvatarForEmpty() {
        XCTAssertEqual(AccountPresentation.avatar(for: ""), "💗")
    }
}

final class CoupleDatesTests: XCTestCase {

    func testDaysSince() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let dateString = formatter.string(from: thirtyDaysAgo)

        let days = CoupleDates.daysSince(dateString)
        XCTAssertEqual(days, 30)
    }

    func testDaysSinceNilDate() {
        XCTAssertNil(CoupleDates.daysSince(nil))
        XCTAssertNil(CoupleDates.daysSince(""))
    }

    func testDaysUntil() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let dateString = formatter.string(from: tomorrow)

        let days = CoupleDates.daysUntil(dateString)
        XCTAssertEqual(days, 1)
    }
}
