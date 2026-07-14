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
        let targetView = selectedId.flatMap { mediaHost?.transitionTargetView(for: $0) }
        let targetGeometry = transitionGeometry(
            targetView: targetView,
            contentView: contentView,
            container: container)
        let sourceTransform = transform(
            from: source,
            in: container,
            targetSize: targetGeometry.size,
            targetCenter: targetGeometry.center,
            transformCenter: targetGeometry.transformCenter)
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

    private func transitionGeometry(
        targetView: UIView?,
        contentView: UIView,
        container: UIView
    ) -> (size: CGSize, center: CGPoint, transformCenter: CGPoint) {
        let targetFrameInContent: CGRect
        if let targetView, targetView.bounds.width > 0, targetView.bounds.height > 0 {
            // 转到 contentView 自身坐标时，不会包含 contentView 上的交互式退出 transform。
            targetFrameInContent = targetView.convert(targetView.bounds, to: contentView)
        } else {
            targetFrameInContent = contentView.bounds
        }
        let centerInContent = CGPoint(
            x: targetFrameInContent.midX,
            y: targetFrameInContent.midY)
        return (
            targetFrameInContent.size,
            untransformedPoint(centerInContent, in: contentView, container: container),
            untransformedPoint(
                CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY),
                in: contentView,
                container: container))
    }

    private func untransformedPoint(
        _ point: CGPoint,
        in view: UIView,
        container: UIView
    ) -> CGPoint {
        guard let superview = view.superview else { return point }
        let boundsCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let pointInSuperview = CGPoint(
            x: view.center.x + point.x - boundsCenter.x,
            y: view.center.y + point.y - boundsCenter.y)
        return superview.convert(pointInSuperview, to: container)
    }

    private func transform(
        from source: UIView?,
        in container: UIView,
        targetSize: CGSize,
        targetCenter: CGPoint,
        transformCenter: CGPoint
    ) -> CGAffineTransform {
        guard let source, source.window != nil else {
            return CGAffineTransform(scaleX: 0.94, y: 0.94)
        }
        let frame = source.convert(source.bounds, to: container)
        // 全屏浏览使用 aspect-fit。缩放基准必须是屏幕中真正显示出来的媒体矩形，
        // 而不是 hosting view 的整屏边界，否则竖图/横图会缩成源缩略图内部的一张小卡片。
        let sourceSize = source.bounds.size
        let fitScale = min(
            targetSize.width / max(1, sourceSize.width),
            targetSize.height / max(1, sourceSize.height))
        let displayedSize = CGSize(
            width: sourceSize.width * fitScale,
            height: sourceSize.height * fitScale)
        let scale = max(0.12, min(
            frame.width / max(1, displayedSize.width),
            frame.height / max(1, displayedSize.height)))
        // UIView 的 transform 围绕 contentView 的中心缩放。媒体页中心若不在该点，
        // 它与缩放中心之间的距离也会乘以 scale，平移必须把这部分一起纳入。
        let scaledTargetCenter = CGPoint(
            x: transformCenter.x + (targetCenter.x - transformCenter.x) * scale,
            y: transformCenter.y + (targetCenter.y - transformCenter.y) * scale)
        let translation = CGPoint(
            x: frame.midX - scaledTargetCenter.x,
            y: frame.midY - scaledTargetCenter.y)
        // 明确写出矩阵，确保缩放不会改变已经算好的中心点平移量。
        return CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: scale,
            tx: translation.x, ty: translation.y)
    }
}
