import UIKit

final class MediaViewerInteractionController: NSObject, UIGestureRecognizerDelegate {
    private weak var viewController: MediaViewerHostController?
    private let canStart: () -> Bool
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))

    init(viewController: MediaViewerHostController, canStart: @escaping () -> Bool) {
        self.viewController = viewController
        self.canStart = canStart
        super.init()
        pan.delegate = self
        pan.cancelsTouchesInView = true
        viewController.view.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canStart(), let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return MediaViewerTransitionMetrics.axis(translation: .zero, velocity: velocity) == .vertical
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // 一旦纵向退出手势成立，就独占本次触摸，避免底层分页 ScrollView
        // 同时接收横向位移而出现斜着翻页、退出两套动画互相抢占。
        false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        switch gesture.state {
        case .began:
            NotificationCenter.default.post(name: .mediaViewerPauseVideo, object: nil)
        case .changed:
            viewController?.updateInteractiveDismissal(translationY: translation.y)
        case .ended:
            let shouldFinish = MediaViewerTransitionMetrics.shouldFinish(
                translationY: translation.y,
                velocityY: velocity.y,
                height: view.bounds.height)
            if shouldFinish {
                viewController?.dismiss(animated: true)
            } else {
                viewController?.restoreInteractiveDismissal()
                NotificationCenter.default.post(name: .mediaViewerResumeVideo, object: nil)
            }
        case .cancelled, .failed:
            viewController?.restoreInteractiveDismissal()
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
