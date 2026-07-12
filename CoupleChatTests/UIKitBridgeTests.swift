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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date())!
        let dateString = formatter.string(from: tomorrow)

        let days = CoupleDates.daysUntil(dateString)
        XCTAssertEqual(days, 1)
    }
}

final class InteractionNoteLayoutTests: XCTestCase {
    func testRandomPositionsKeepCardInsidePhoneBounds() {
        let container = CGSize(width: 390, height: 844)
        let card = CGSize(width: 270, height: 260)

        for seed in 0..<997 {
            let point = InteractionNoteLayout.position(
                seed: seed,
                container: container,
                cardSize: card)
            XCTAssertGreaterThanOrEqual(point.x - card.width / 2, 24)
            XCTAssertLessThanOrEqual(point.x + card.width / 2, container.width - 24)
            XCTAssertGreaterThanOrEqual(point.y - card.height / 2, 72)
            XCTAssertLessThanOrEqual(point.y + card.height / 2, container.height - 52)
        }
    }

    func testCompactPhoneStillProducesAValidPosition() {
        let point = InteractionNoteLayout.position(
            seed: 428,
            container: CGSize(width: 320, height: 568),
            cardSize: CGSize(width: 270, height: 260))

        XCTAssertGreaterThanOrEqual(point.x - 135, 24)
        XCTAssertLessThanOrEqual(point.x + 135, 296)
        XCTAssertGreaterThanOrEqual(point.y - 130, 72)
        XCTAssertLessThanOrEqual(point.y + 130, 516)
    }
}
