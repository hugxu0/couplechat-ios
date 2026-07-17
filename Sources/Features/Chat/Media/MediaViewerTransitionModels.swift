import SwiftUI
import UIKit

@MainActor
final class MediaViewerSourceRegistry {
    private let views = NSMapTable<NSString, UIView>(
        keyOptions: .strongMemory,
        valueOptions: .weakMemory)

    func register(_ view: UIView, id: String) {
        views.setObject(view, forKey: id as NSString)
    }

    func view(for id: String) -> UIView? {
        views.object(forKey: id as NSString)
    }
}

struct MediaViewerSourceAnchor: UIViewRepresentable {
    let id: String
    let registry: MediaViewerSourceRegistry

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        registry.register(view, id: id)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        registry.register(uiView, id: id)
    }
}

enum MediaViewerGestureAxis: Equatable {
    case horizontal
    case vertical
    case undecided
}

enum MediaViewerTransitionMetrics {
    static let dismissalDistance: CGFloat = 120
    static let dismissalVelocity: CGFloat = 900

    static func axis(translation: CGSize, velocity: CGPoint) -> MediaViewerGestureAxis {
        let horizontal = max(abs(translation.width), abs(velocity.x) * 0.08)
        let vertical = max(abs(translation.height), abs(velocity.y) * 0.08)
        guard max(horizontal, vertical) >= 8 else { return .undecided }
        return vertical > horizontal * 1.12 ? .vertical : .horizontal
    }

    static func progress(translationY: CGFloat, height: CGFloat) -> CGFloat {
        min(1, abs(translationY) / max(240, height * 0.32))
    }

    static func scale(progress: CGFloat) -> CGFloat {
        max(0.78, 1 - min(1, max(0, progress)) * 0.22)
    }

    static func backgroundAlpha(progress: CGFloat) -> CGFloat {
        max(0, 1 - min(1, max(0, progress)) * 1.18)
    }

    static func interactiveTransform(translationY: CGFloat, height: CGFloat) -> CGAffineTransform {
        let clampedProgress = progress(translationY: translationY, height: height)
        return CGAffineTransform(
            translationX: 0,
            y: translationY
        )
        .scaledBy(
            x: scale(progress: clampedProgress),
            y: scale(progress: clampedProgress))
    }

    static func shouldFinish(translationY: CGFloat, velocityY: CGFloat, height: CGFloat) -> Bool {
        abs(translationY) >= dismissalDistance || abs(velocityY) >= dismissalVelocity
    }
}
