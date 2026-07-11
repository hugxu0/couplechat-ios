import UIKit

final class MediaViewerInteractionController: UIPercentDrivenInteractiveTransition, UIGestureRecognizerDelegate {
    private weak var viewController: UIViewController?
    private let canStart: () -> Bool
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private(set) var isInteracting = false

    init(viewController: UIViewController, canStart: @escaping () -> Bool) {
        self.viewController = viewController
        self.canStart = canStart
        super.init()
        completionCurve = .easeOut
        pan.delegate = self
        viewController.view.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canStart(), let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return velocity.y > 0
            && MediaViewerTransitionMetrics.axis(translation: .zero, velocity: velocity) == .vertical
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let progress = MediaViewerTransitionMetrics.progress(
            translationY: translation.y,
            height: view.bounds.height)

        switch gesture.state {
        case .began:
            isInteracting = true
            NotificationCenter.default.post(name: .mediaViewerPauseVideo, object: nil)
            viewController?.dismiss(animated: true)
        case .changed:
            update(progress)
        case .ended:
            let shouldFinish = MediaViewerTransitionMetrics.shouldFinish(
                translationY: translation.y,
                velocityY: velocity.y,
                height: view.bounds.height)
            isInteracting = false
            if shouldFinish {
                finish()
            } else {
                cancel()
                NotificationCenter.default.post(name: .mediaViewerResumeVideo, object: nil)
            }
        case .cancelled, .failed:
            isInteracting = false
            cancel()
            NotificationCenter.default.post(name: .mediaViewerResumeVideo, object: nil)
        default:
            break
        }
    }
}

extension Notification.Name {
    static let mediaViewerPauseVideo = Notification.Name("MediaViewerPauseVideo")
    static let mediaViewerResumeVideo = Notification.Name("MediaViewerResumeVideo")
}
