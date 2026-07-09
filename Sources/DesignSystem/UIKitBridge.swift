import SwiftUI
import UIKit

/// 通用 SwiftUI ↔ UIKit 桥接容器。
/// 用于将 UIKit 视图控制器嵌入 SwiftUI 视图树，
/// 统一处理生命周期、环境对象传递和尺寸适配。
///
/// 用法：
/// ```swift
/// UIKitBridge { store, theme in
///     MyViewController(store: store, theme: theme)
/// }
/// .environmentObject(store)
/// .environmentObject(theme)
/// ```
struct UIKitBridge<ViewController: UIViewController>: UIViewControllerRepresentable {
    let makeController: (ChatStore, ThemeManager) -> ViewController
    let updateController: (ViewController, ChatStore, ThemeManager) -> Void

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    init(
        make: @escaping (ChatStore, ThemeManager) -> ViewController,
        update: @escaping (ViewController, ChatStore, ThemeManager) -> Void = { _, _, _ in }
    ) {
        self.makeController = make
        self.updateController = update
    }

    func makeUIViewController(context: Context) -> ViewController {
        makeController(store, theme)
    }

    func updateUIViewController(_ controller: ViewController, context: Context) {
        updateController(controller, store, theme)
    }
}

/// 简化版桥接：不需要环境对象的纯 UIKit 视图。
struct SimpleUIKitBridge<ViewController: UIViewController>: UIViewControllerRepresentable {
    let makeController: () -> ViewController

    init(make: @escaping () -> ViewController) {
        self.makeController = make
    }

    func makeUIViewController(context: Context) -> ViewController {
        makeController()
    }

    func updateUIViewController(_ controller: ViewController, context: Context) {}
}
