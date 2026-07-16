import UIKit
import XCTest
@testable import CoupleChat

@MainActor
final class DajuModelViewTests: XCTestCase {
    func testFailedModelLoadStopsSpinnerAndKeepsFallbackAccessible() throws {
        let view = CatModelContainerView(frame: .zero)
        let spinner = try XCTUnwrap(view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
        XCTAssertTrue(spinner.isAnimating)

        view.finishLoading(success: false)

        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertEqual(view.accessibilityLabel, "大橘的三维模型暂时无法加载")
    }

    func testSuccessfulModelLoadAlsoStopsSpinner() throws {
        let view = CatModelContainerView(frame: .zero)
        let spinner = try XCTUnwrap(view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)

        view.finishLoading(success: true)

        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertEqual(view.accessibilityLabel, "大橘的三维模型")
    }
}
