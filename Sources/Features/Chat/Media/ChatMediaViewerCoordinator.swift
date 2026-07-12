import Combine
import SwiftUI
import UIKit

@MainActor
final class MediaViewerSession: ObservableObject {
    @Published var selectedId: String
    var zoomScale: CGFloat = 1
    var onDismiss: (() -> Void)?

    init(selectedId: String) {
        self.selectedId = selectedId
    }

    func requestDismiss() {
        onDismiss?()
    }
}

@MainActor
final class ChatMediaViewerCoordinator: NSObject, UIViewControllerTransitioningDelegate,
    UIAdaptivePresentationControllerDelegate {
    private weak var host: MediaViewerHostController?
    private var session: MediaViewerSession?
    private var sourceProvider: ((String) -> UIView?)?
    private var interactionController: MediaViewerInteractionController?
    var onDismiss: (() -> Void)?

    var isPresented: Bool { host != nil }

    func present(
        from presenter: UIViewController,
        items: [MediaBrowserItem],
        selectedId: String,
        sourceProvider: ((String) -> UIView?)? = nil
    ) {
        guard !items.isEmpty, host == nil else { return }
        let session = MediaViewerSession(selectedId: selectedId)
        let host = MediaViewerHostController(items: items, session: session)
        self.session = session
        self.host = host
        self.sourceProvider = sourceProvider
        host.modalPresentationStyle = .custom
        host.transitioningDelegate = self
        interactionController = MediaViewerInteractionController(
            viewController: host,
            canStart: { session.zoomScale <= 1.01 })
        session.onDismiss = { [weak host] in host?.dismiss(animated: true) }
        presenter.present(host, animated: true)
        host.presentationController?.delegate = self
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        MediaViewerTransitionAnimator(
            presenting: true,
            selectedId: session?.selectedId,
            sourceProvider: sourceProvider)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        MediaViewerTransitionAnimator(
            presenting: false,
            interactiveDismissal: interactionController?.isInteracting == true,
            selectedId: session?.selectedId,
            sourceProvider: sourceProvider,
            completion: { [weak self] in self?.finishSession() })
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        interactionController?.isInteracting == true ? interactionController : nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishSession()
    }

    private func finishSession() {
        guard host != nil || session != nil else { return }
        host = nil
        session = nil
        interactionController = nil
        sourceProvider = nil
        onDismiss?()
    }
}

final class MediaViewerHostController: UIHostingController<AnyView> {
    init(items: [MediaBrowserItem], session: MediaViewerSession) {
        let selection = Binding<String?>(
            get: { session.selectedId },
            set: { value in
                if let value {
                    session.selectedId = value
                } else {
                    session.requestDismiss()
                }
            })
        let content = MediaPagerView(
            items: items,
            selectedId: selection,
            onZoomScaleChange: { session.zoomScale = $0 })
            .environmentObject(MediaFavoriteStore.shared)
        super.init(rootView: AnyView(content))
        view.backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
