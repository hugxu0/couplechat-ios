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

    func dismissIfShowing(messageId: String, animated: Bool = true) {
        guard session?.selectedId == messageId else { return }
        host?.dismiss(animated: animated)
    }

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
            selectedId: session?.selectedId,
            sourceProvider: sourceProvider,
            completion: { [weak self] in self?.finishSession() })
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

final class MediaViewerHostController: UIViewController {
    let backdropView = UIView()
    private let hostingController: UIHostingController<AnyView>
    var transitionContentView: UIView { hostingController.view }

    init(items: [MediaBrowserItem], session: MediaViewerSession) {
        // 由观察 session 的容器建立 Binding。之前只用闭包 Binding，翻页后 SwiftUI
        // 不会因 @Published selectedId 重绘，加载窗口会永远停在最初图片的前后各一张。
        let content = MediaViewerSessionContent(items: items, session: session)
            .environmentObject(MediaFavoriteStore.shared)
        hostingController = UIHostingController(rootView: AnyView(content))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdropView.backgroundColor = .black
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func updateInteractiveDismissal(translationY: CGFloat) {
        let progress = MediaViewerTransitionMetrics.progress(
            translationY: translationY,
            height: view.bounds.height)
        transitionContentView.transform = MediaViewerTransitionMetrics.interactiveTransform(
            translationY: translationY,
            height: view.bounds.height)
        backdropView.alpha = MediaViewerTransitionMetrics.backgroundAlpha(progress: progress)
    }

    func restoreInteractiveDismissal() {
        let animator = UIViewPropertyAnimator(duration: 0.34, dampingRatio: 0.82) {
            self.transitionContentView.transform = .identity
            self.transitionContentView.alpha = 1
            self.backdropView.alpha = 1
        }
        animator.startAnimation()
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(requestDismiss),
            discoverabilityTitle: "关闭预览")]
    }

    override func accessibilityPerformEscape() -> Bool {
        requestDismiss()
        return true
    }

    @objc private func requestDismiss() {
        dismiss(animated: true)
    }
}

private struct MediaViewerSessionContent: View {
    let items: [MediaBrowserItem]
    @ObservedObject var session: MediaViewerSession

    var body: some View {
        MediaPagerView(
            items: items,
            selectedId: Binding(
                get: { session.selectedId },
                set: { value in
                    if let value { session.selectedId = value }
                    else { session.requestDismiss() }
                }),
            showsBackdrop: false,
            onZoomScaleChange: { session.zoomScale = $0 })
    }
}
