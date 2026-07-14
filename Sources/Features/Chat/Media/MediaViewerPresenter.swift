import SwiftUI
import UIKit

struct MediaViewerPresenter: UIViewControllerRepresentable {
    let items: [MediaBrowserItem]
    @Binding var selectedId: String?
    var sourceProvider: ((String) -> UIView?)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedId: $selectedId)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isHidden = true
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.selectedId = $selectedId
        context.coordinator.sourceProvider = sourceProvider
        guard let selectedId, !context.coordinator.viewer.isPresented else { return }
        DispatchQueue.main.async {
            guard controller.view.window != nil else { return }
            let presenter = context.coordinator.presentationHost(from: controller)
            context.coordinator.viewer.present(
                from: presenter,
                items: items,
                selectedId: selectedId,
                sourceProvider: context.coordinator.sourceProvider)
        }
    }

    @MainActor
    final class Coordinator {
        let viewer = ChatMediaViewerCoordinator()
        var selectedId: Binding<String?>
        var sourceProvider: ((String) -> UIView?)?

        init(selectedId: Binding<String?>) {
            self.selectedId = selectedId
            sourceProvider = nil
            viewer.onDismiss = { [weak self] in self?.selectedId.wrappedValue = nil }
        }

        func presentationHost(from controller: UIViewController) -> UIViewController {
            var candidate = controller
            while let parent = candidate.parent { candidate = parent }
            while let presented = candidate.presentedViewController { candidate = presented }
            return candidate
        }
    }
}
