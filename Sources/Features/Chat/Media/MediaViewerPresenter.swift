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
        // 不能隐藏承载控制器：隐藏视图在部分 SwiftUI 层级里不会获得 window，
        // 于是选中媒体后没有可用于 present 的宿主，看起来就像点击无反应。
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.selectedId = $selectedId
        context.coordinator.sourceProvider = sourceProvider
        guard let selectedId, !context.coordinator.viewer.isPresented else { return }
        context.coordinator.presentWhenReady(
            from: controller,
            items: items,
            selectedId: selectedId)
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

        func presentWhenReady(
            from controller: UIViewController,
            items: [MediaBrowserItem],
            selectedId: String,
            attempt: Int = 0
        ) {
            guard self.selectedId.wrappedValue == selectedId, !viewer.isPresented else { return }
            guard controller.view.window != nil else {
                guard attempt < 6 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.presentWhenReady(
                        from: controller,
                        items: items,
                        selectedId: selectedId,
                        attempt: attempt + 1)
                }
                return
            }
            let presenter = presentationHost(from: controller)
            viewer.present(
                from: presenter,
                items: items,
                selectedId: selectedId,
                sourceProvider: sourceProvider)
        }

        func presentationHost(from controller: UIViewController) -> UIViewController {
            var candidate = controller
            while let parent = candidate.parent { candidate = parent }
            while let presented = candidate.presentedViewController { candidate = presented }
            return candidate
        }
    }
}
