import CoreGraphics

enum MediaViewerGestureAxis: Equatable {
    case horizontal
    case vertical
    case undecided
}

enum MediaViewerTransitionMetrics {
    static func axis(translation: CGSize, velocity: CGPoint) -> MediaViewerGestureAxis {
        let horizontal = max(abs(translation.width), abs(velocity.x) * 0.08)
        let vertical = max(abs(translation.height), abs(velocity.y) * 0.08)
        guard max(horizontal, vertical) >= 8 else { return .undecided }
        return vertical > horizontal * 1.12 ? .vertical : .horizontal
    }

    static func progress(translationY: CGFloat, height: CGFloat) -> CGFloat {
        min(1, max(0, translationY / max(1, height * 0.72)))
    }

    static func scale(progress: CGFloat) -> CGFloat {
        max(0.78, 1 - min(1, max(0, progress)) * 0.22)
    }

    static func backgroundAlpha(progress: CGFloat) -> CGFloat {
        max(0, 1 - min(1, max(0, progress)) * 1.18)
    }

    static func interactiveTransform(progress: CGFloat, height: CGFloat) -> CGAffineTransform {
        let clampedProgress = min(1, max(0, progress))
        return CGAffineTransform(
            translationX: 0,
            y: max(1, height) * 0.72 * clampedProgress
        )
        .scaledBy(
            x: scale(progress: clampedProgress),
            y: scale(progress: clampedProgress))
    }

    static func shouldFinish(translationY: CGFloat, velocityY: CGFloat, height: CGFloat) -> Bool {
        progress(translationY: translationY, height: height) >= 0.32 || velocityY >= 950
    }
}
