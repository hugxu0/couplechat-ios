import UIKit

final class MediaViewerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    private let selectedId: String?
    private let sourceProvider: ((String) -> UIView?)?
    private let completion: (() -> Void)?
    private var animator: UIViewPropertyAnimator?
    private var completedDismissal = false

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
        let animator = interruptibleAnimator(using: transitionContext)
        if animator.state == .inactive { animator.startAnimation() }
    }

    func interruptibleAnimator(
        using transitionContext: UIViewControllerContextTransitioning
    ) -> UIViewImplicitlyAnimating {
        if let animator { return animator }
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key) else {
            transitionContext.completeTransition(false)
            return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }
        let container = transitionContext.containerView
        let view = controller.view!
        if presenting {
            view.frame = transitionContext.finalFrame(for: controller)
            container.addSubview(view)
        }

        let source = selectedId.flatMap { sourceProvider?($0) }
        let sourceTransform = transform(from: source, in: container, target: view.bounds)
        if presenting {
            view.alpha = 0
            view.transform = sourceTransform
        }

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            dampingRatio: 0.9
        ) {
            view.alpha = self.presenting ? 1 : 0
            view.transform = self.presenting ? .identity : sourceTransform
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            let completed = position == .end && !transitionContext.transitionWasCancelled
            if !completed {
                view.alpha = 1
                view.transform = .identity
            }
            transitionContext.completeTransition(completed)
            self.animator = nil
            if completed { self.completeDismissalIfNeeded() }
        }
        self.animator = animator
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        if transitionCompleted { completeDismissalIfNeeded() }
        animator = nil
    }

    private func completeDismissalIfNeeded() {
        guard !presenting, !completedDismissal else { return }
        completedDismissal = true
        completion?()
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
