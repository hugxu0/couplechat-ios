import UIKit

final class MediaViewerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool
    private let selectedId: String?
    private let sourceProvider: ((String) -> UIView?)?
    private let completion: (() -> Void)?
    private var animator: UIViewPropertyAnimator?
    private var transitionProxy: UIView?
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
        presenting ? 0.38 : 0.30
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

        let mediaHost = controller as? MediaViewerHostController
        let contentView = mediaHost?.transitionContentView ?? view
        let backdropView = mediaHost?.backdropView

        if presenting {
            return makePresentationAnimator(
                transitionContext: transitionContext,
                container: container,
                contentView: contentView,
                backdropView: backdropView)
        }

        return makeDismissalAnimator(
            transitionContext: transitionContext,
            container: container,
            contentView: contentView,
            backdropView: backdropView,
            mediaHost: mediaHost)
    }

    func animationEnded(_ transitionCompleted: Bool) {
        if transitionCompleted { completeDismissalIfNeeded() }
        transitionProxy?.removeFromSuperview()
        transitionProxy = nil
        animator = nil
    }

    private func makePresentationAnimator(
        transitionContext: UIViewControllerContextTransitioning,
        container: UIView,
        contentView: UIView,
        backdropView: UIView?
    ) -> UIViewPropertyAnimator {
        let source = selectedId.flatMap { sourceProvider?($0) }
        // Presentation grows the square tile into the viewer's full canvas. The
        // actual fitted image rect is only needed for the reverse transition.
        let targetGeometry = transitionGeometry(
            targetView: nil,
            contentView: contentView,
            container: container)
        let sourceTransform = transform(
            from: source,
            in: container,
            targetSize: targetGeometry.size,
            targetCenter: targetGeometry.center,
            transformCenter: targetGeometry.transformCenter)

        backdropView?.alpha = 0
        contentView.alpha = 0
        contentView.transform = sourceTransform

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            dampingRatio: 0.9
        ) {
            backdropView?.alpha = 1
            contentView.alpha = 1
            contentView.transform = .identity
        }
        animator.addCompletion { [weak self] position in
            let completed = position == .end && !transitionContext.transitionWasCancelled
            if !completed {
                backdropView?.alpha = 0
                contentView.alpha = 0
                contentView.transform = sourceTransform
            }
            transitionContext.completeTransition(completed)
            self?.animator = nil
        }
        self.animator = animator
        return animator
    }

    private func makeDismissalAnimator(
        transitionContext: UIViewControllerContextTransitioning,
        container: UIView,
        contentView: UIView,
        backdropView: UIView?,
        mediaHost: MediaViewerHostController?
    ) -> UIViewPropertyAnimator {
        let source = selectedId.flatMap { sourceProvider?($0) }
        let target = selectedId.flatMap { mediaHost?.transitionTargetView(for: $0) }

        if let source,
           let target,
           let proxyAnimator = makeProxyDismissalAnimator(
               transitionContext: transitionContext,
               container: container,
               contentView: contentView,
               backdropView: backdropView,
               source: source,
               target: target) {
            return proxyAnimator
        }

        return makeFallbackDismissalAnimator(
            transitionContext: transitionContext,
            container: container,
            contentView: contentView,
            backdropView: backdropView,
            source: source)
    }

    private func makeProxyDismissalAnimator(
        transitionContext: UIViewControllerContextTransitioning,
        container: UIView,
        contentView: UIView,
        backdropView: UIView?,
        source: UIView,
        target: UIView
    ) -> UIViewPropertyAnimator? {
        guard source.window != nil,
              target.window != nil,
              contentView.bounds.width > 0,
              contentView.bounds.height > 0 else { return nil }

        let mediaRectInContent = target.convert(target.bounds, to: contentView)
        let targetFrame = target.convert(target.bounds, to: container)
        let sourceFrame = source.convert(source.bounds, to: container)
        let isCanvasTarget = abs(mediaRectInContent.width - contentView.bounds.width) < 1
            && abs(mediaRectInContent.height - contentView.bounds.height) < 1
        // A video page (or an image that has not reported its intrinsic size yet)
        // only has a full-canvas anchor. Keep the safe legacy fallback for it;
        // cropping a whole canvas would also capture its letterbox/background.
        guard !isCanvasTarget else { return nil }
        guard mediaRectInContent.width > 0,
              mediaRectInContent.height > 0,
              targetFrame.width > 0,
              targetFrame.height > 0,
              sourceFrame.width > 0,
              sourceFrame.height > 0,
              let snapshot = contentView.snapshotView(afterScreenUpdates: false) else {
            return nil
        }

        let proxy = UIView()
        proxy.backgroundColor = .clear
        proxy.clipsToBounds = true
        proxy.layer.cornerCurve = .continuous
        proxy.bounds = CGRect(origin: .zero, size: targetFrame.size)
        proxy.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)

        snapshot.bounds = contentView.bounds
        proxy.addSubview(snapshot)

        let mediaOffset = CGPoint(
            x: mediaRectInContent.midX - contentView.bounds.midX,
            y: mediaRectInContent.midY - contentView.bounds.midY)
        let initialScaleX = targetFrame.width / mediaRectInContent.width
        let initialScaleY = targetFrame.height / mediaRectInContent.height
        snapshot.transform = CGAffineTransform(scaleX: initialScaleX, y: initialScaleY)
        snapshot.center = CGPoint(
            x: proxy.bounds.midX - mediaOffset.x * initialScaleX,
            y: proxy.bounds.midY - mediaOffset.y * initialScaleY)

        container.addSubview(proxy)
        transitionProxy = proxy
        contentView.alpha = 0

        let finalScale = max(
            sourceFrame.width / mediaRectInContent.width,
            sourceFrame.height / mediaRectInContent.height)
        let finalSnapshotCenter = CGPoint(
            x: sourceFrame.width / 2 - mediaOffset.x * finalScale,
            y: sourceFrame.height / 2 - mediaOffset.y * finalScale)

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            dampingRatio: 0.92
        ) {
            // Changing the proxy's bounds and the snapshot's fill scale together
            // turns the original aspect-fit image into the cover's aspect-fill crop.
            proxy.bounds = CGRect(origin: .zero, size: sourceFrame.size)
            proxy.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
            proxy.layer.cornerRadius = 8
            snapshot.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
            snapshot.center = finalSnapshotCenter
            backdropView?.alpha = 0
        }
        animator.addCompletion { [weak self] position in
            let completed = position == .end && !transitionContext.transitionWasCancelled
            proxy.removeFromSuperview()
            self?.transitionProxy = nil
            contentView.alpha = 1
            if !completed {
                contentView.transform = .identity
                backdropView?.alpha = 1
            }
            transitionContext.completeTransition(completed)
            if completed { self?.completeDismissalIfNeeded() }
            self?.animator = nil
        }
        self.animator = animator
        return animator
    }

    private func makeFallbackDismissalAnimator(
        transitionContext: UIViewControllerContextTransitioning,
        container: UIView,
        contentView: UIView,
        backdropView: UIView?,
        source: UIView?
    ) -> UIViewPropertyAnimator {
        let targetGeometry = transitionGeometry(
            targetView: nil,
            contentView: contentView,
            container: container)
        let dismissalTransform = transform(
            from: source,
            in: container,
            targetSize: targetGeometry.size,
            targetCenter: targetGeometry.center,
            transformCenter: targetGeometry.transformCenter)

        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            dampingRatio: 0.9
        ) {
            backdropView?.alpha = 0
            contentView.alpha = 1
            contentView.transform = dismissalTransform
        }
        animator.addCompletion { [weak self] position in
            let completed = position == .end && !transitionContext.transitionWasCancelled
            if !completed {
                backdropView?.alpha = 1
                contentView.alpha = 1
                contentView.transform = .identity
            }
            transitionContext.completeTransition(completed)
            self?.animator = nil
            if completed { self?.completeDismissalIfNeeded() }
        }
        self.animator = animator
        return animator
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
        let scaledTargetCenter = CGPoint(
            x: transformCenter.x + (targetCenter.x - transformCenter.x) * scale,
            y: transformCenter.y + (targetCenter.y - transformCenter.y) * scale)
        let translation = CGPoint(
            x: frame.midX - scaledTargetCenter.x,
            y: frame.midY - scaledTargetCenter.y)
        return CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: scale,
            tx: translation.x, ty: translation.y)
    }
}
