import UIKit

final class MediaViewerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    private let selectedId: String?
    private let sourceProvider: ((String) -> UIView?)?
    private let completion: (() -> Void)?

    init(
        presenting: Bool,
        selectedId: String?,
        sourceProvider: ((String) -> UIView?)?,
        completion: (() -> Void)? = nil
    ) {
        self.presenting = presenting
        self.selectedId = selectedId
        self.sourceProvider = sourceProvider
        self.completion = completion
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        presenting ? 0.34 : 0.28
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key) else {
            transitionContext.completeTransition(false)
            return
        }
        let container = transitionContext.containerView
        let view = controller.view!
        if presenting {
            view.frame = transitionContext.finalFrame(for: controller)
            container.addSubview(view)
        }

        let source = selectedId.flatMap { sourceProvider?($0) }
        let initialTransform = transform(from: source, in: container, target: view.bounds)
        if presenting {
            view.alpha = 0
            view.transform = initialTransform
        }

        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            view.alpha = self.presenting ? 1 : 0
            view.transform = self.presenting ? .identity : initialTransform
        } completion: { _ in
            let completed = !transitionContext.transitionWasCancelled
            if !completed {
                view.alpha = 1
                view.transform = .identity
            }
            transitionContext.completeTransition(completed)
            if completed && !self.presenting { self.completion?() }
        }
    }

    private func transform(from source: UIView?, in container: UIView, target: CGRect) -> CGAffineTransform {
        guard let source, source.window != nil else {
            return CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
        let frame = source.convert(source.bounds, to: container)
        let scale = max(0.12, min(frame.width / max(1, target.width), frame.height / max(1, target.height)))
        let translation = CGPoint(x: frame.midX - target.midX, y: frame.midY - target.midY)
        return CGAffineTransform(translationX: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)
    }
}
