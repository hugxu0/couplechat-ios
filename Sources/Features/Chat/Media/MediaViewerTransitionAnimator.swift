import UIKit

final class MediaViewerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    private let interactiveDismissal: Bool
    private let selectedId: String?
    private let sourceProvider: ((String) -> UIView?)?
    private let completion: (() -> Void)?
    private var animator: UIViewPropertyAnimator?
    private var completedDismissal = false

    init(
        presenting: Bool,
        interactiveDismissal: Bool = false,
        selectedId: String?,
        sourceProvider: ((String) -> UIView?)?,
        completion: (() -> Void)? = nil
    ) {
        self.presenting = presenting
        self.interactiveDismissal = interactiveDismissal
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
        view.layoutIfNeeded()

        // 遮罩保持铺满屏幕并单独淡出；只让媒体内容跟随退出手势移动和缩放。
        // 这样 aspect-fit 留出的区域不会变成一起滑动的黑色矩形。
        let mediaHost = controller as? MediaViewerHostController
        let contentView = mediaHost?.transitionContentView ?? view
        let backdropView = mediaHost?.backdropView

        let source = selectedId.flatMap { sourceProvider?($0) }
        let sourceTransform = transform(from: source, in: container, target: contentView.bounds)
        let dismissalTransform = interactiveDismissal
            ? MediaViewerTransitionMetrics.interactiveTransform(progress: 1, height: container.bounds.height)
            : sourceTransform
        if presenting {
            backdropView?.alpha = 0
            contentView.alpha = 0
            contentView.transform = sourceTransform
        }

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            dampingRatio: 0.9
        ) {
            backdropView?.alpha = self.presenting ? 1 : 0
            contentView.alpha = self.presenting ? 1 : 0
            contentView.transform = self.presenting ? .identity : dismissalTransform
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            let completed = position == .end && !transitionContext.transitionWasCancelled
            if !completed {
                backdropView?.alpha = 1
                contentView.alpha = 1
                contentView.transform = .identity
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
