import XCTest
@testable import CoupleChat

final class MediaViewerTransitionMetricsTests: XCTestCase {
    func testVerticalIntentMustClearlyExceedHorizontalIntent() {
        XCTAssertEqual(
            MediaViewerTransitionMetrics.axis(
                translation: CGSize(width: 8, height: 40),
                velocity: CGPoint(x: 20, y: 260)),
            .vertical)
        XCTAssertEqual(
            MediaViewerTransitionMetrics.axis(
                translation: CGSize(width: 45, height: 20),
                velocity: CGPoint(x: 300, y: 80)),
            .horizontal)
    }

    func testProgressAndVisualValuesAreClamped() {
        XCTAssertEqual(MediaViewerTransitionMetrics.progress(translationY: -20, height: 800), 0)
        XCTAssertEqual(MediaViewerTransitionMetrics.progress(translationY: 900, height: 800), 1)
        XCTAssertEqual(MediaViewerTransitionMetrics.scale(progress: 1), 0.78)
        XCTAssertEqual(MediaViewerTransitionMetrics.backgroundAlpha(progress: 1), 0)
    }

    func testInteractiveTransformTracksFingerDistanceAndScale() {
        let transform = MediaViewerTransitionMetrics.interactiveTransform(progress: 0.5, height: 800)
        XCTAssertEqual(transform.ty, 288, accuracy: 0.001)
        XCTAssertEqual(transform.a, 0.89, accuracy: 0.001)
        XCTAssertEqual(transform.d, 0.89, accuracy: 0.001)
    }

    func testDismissalUsesDistanceOrVelocity() {
        XCTAssertTrue(MediaViewerTransitionMetrics.shouldFinish(
            translationY: 200, velocityY: 100, height: 800))
        XCTAssertTrue(MediaViewerTransitionMetrics.shouldFinish(
            translationY: 30, velocityY: 1_100, height: 800))
        XCTAssertFalse(MediaViewerTransitionMetrics.shouldFinish(
            translationY: 60, velocityY: 300, height: 800))
    }
}
