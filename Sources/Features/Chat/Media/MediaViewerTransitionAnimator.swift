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
        0.38
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
        let dismissalTransform = sourceTransform
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
            // 退出时媒体始终保持不透明，只通过缩放回到聊天中的原位置。
            contentView.alpha = 1
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
        // 全屏浏览使用 aspect-fit。缩放基准必须是屏幕中真正显示出来的媒体矩形，
        // 而不是 hosting view 的整屏边界，否则竖图/横图会缩成源缩略图内部的一张小卡片。
        let sourceSize = source.bounds.size
        let fitScale = min(
            target.width / max(1, sourceSize.width),
            target.height / max(1, sourceSize.height))
        let displayedSize = CGSize(
            width: sourceSize.width * fitScale,
            height: sourceSize.height * fitScale)
        let scale = max(0.12, min(
            frame.width / max(1, displayedSize.width),
            frame.height / max(1, displayedSize.height)))
        let translation = CGPoint(x: frame.midX - target.midX, y: frame.midY - target.midY)
        return CGAffineTransform(translationX: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)
    }
}
