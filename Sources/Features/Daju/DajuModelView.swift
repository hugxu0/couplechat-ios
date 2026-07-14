import GLTFKit2
import SceneKit
import SwiftUI
import UIKit

/// 把用户提供的 GLB 模型放进原生 SceneKit 画布。加载失败时保留轻量占位，
/// 页面其他互动仍可使用，不让一个资源错误拖垮整个大橘页。
struct DajuModelView: UIViewRepresentable {
    let reactionID: UUID
    let reaction: PetInteractionKind

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CatModelContainerView {
        let view = CatModelContainerView()
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: CatModelContainerView, context: Context) {
        context.coordinator.react(id: reactionID, kind: reaction)
    }

    final class Coordinator {
        private weak var container: CatModelContainerView?
        private var modelRoot: SCNNode?
        private var lastReactionID: UUID?
        private var isLoading = false

        func attach(_ container: CatModelContainerView) {
            self.container = container
            loadModelIfNeeded()
        }

        func react(id: UUID, kind: PetInteractionKind) {
            guard lastReactionID != id else { return }
            lastReactionID = id
            guard let modelRoot else { return }
            let action: SCNAction
            switch kind {
            case .feed:
                action = .sequence([
                    .scale(by: 1.04, duration: 0.16),
                    .scale(by: 1 / 1.04, duration: 0.22),
                ])
            case .bathe:
                action = .sequence([
                    .moveBy(x: 0, y: 0.06, z: 0, duration: 0.12),
                    .moveBy(x: 0, y: -0.06, z: 0, duration: 0.18),
                ])
            case .play:
                action = .sequence([
                    .moveBy(x: 0, y: 0.15, z: 0, duration: 0.15),
                    .moveBy(x: 0, y: -0.15, z: 0, duration: 0.22),
                ])
            case .stroke:
                action = .sequence([
                    .scale(by: 1.05, duration: 0.14),
                    .scale(by: 1 / 1.05, duration: 0.22),
                ])
            case .sleep:
                action = .sequence([
                    .scale(by: 0.95, duration: 0.25),
                    .wait(duration: 0.18),
                    .scale(by: 1 / 0.95, duration: 0.24),
                ])
            }
            modelRoot.removeAction(forKey: "pet-reaction")
            modelRoot.runAction(action, forKey: "pet-reaction")
        }

        private func loadModelIfNeeded() {
            guard !isLoading, modelRoot == nil,
                  let url = Bundle.main.url(forResource: "cute_cat", withExtension: "glb") else {
                return
            }
            isLoading = true
            GLTFAsset.load(with: url, options: [:]) { [weak self] _, status, asset, _, _ in
                guard let self, status == .complete, let asset else { return }
                let source = GLTFSCNSceneSource(asset: asset)
                guard let loadedScene = source.defaultScene else { return }
                DispatchQueue.main.async {
                    self.install(loadedScene)
                }
            }
        }

        private func install(_ loadedScene: SCNScene) {
            guard let container else { return }
            let presentationScene = SCNScene()
            let pivot = SCNNode()
            let content = SCNNode()
            for child in loadedScene.rootNode.childNodes {
                content.addChildNode(child.clone())
            }
            // 模型内容只负责缩放与居中，外层 pivot 只负责水平旋转。
            // 两者分开后旋转轴会稳定穿过身体中心，不再绕偏移后的节点公转。
            normalize(content)
            // 资源文件的正面轴与 SceneKit 相机相差 90°。只校正外层 yaw，
            // 之后的拖动仍围绕同一身体中心水平旋转。
            pivot.eulerAngles.y = .pi / 2
            pivot.addChildNode(content)
            presentationScene.rootNode.addChildNode(pivot)
            presentationScene.rootNode.addChildNode(cameraNode())
            presentationScene.rootNode.addChildNode(keyLight())
            presentationScene.rootNode.addChildNode(fillLight())
            presentationScene.rootNode.addChildNode(ambientLight())
            container.sceneView.scene = presentationScene
            container.setModelRoot(pivot)
            container.setLoaded(true)
            modelRoot = pivot
        }

        private func normalize(_ node: SCNNode) {
            let (minimum, maximum) = node.boundingBox
            let width = maximum.x - minimum.x
            let height = maximum.y - minimum.y
            let depth = maximum.z - minimum.z
            let largest = max(width, max(height, depth))
            guard largest > 0 else { return }
            let scale = 1.5 / largest
            node.scale = SCNVector3(scale, scale, scale)
            node.position = SCNVector3(
                -(minimum.x + maximum.x) * scale / 2,
                -(minimum.y + maximum.y) * scale / 2 - 0.05,
                -(minimum.z + maximum.z) * scale / 2)
        }

        private func cameraNode() -> SCNNode {
            let node = SCNNode()
            let camera = SCNCamera()
            camera.fieldOfView = 34
            camera.zNear = 0.01
            camera.zFar = 100
            node.camera = camera
            node.position = SCNVector3(0, 0.12, 4.1)
            node.look(at: SCNVector3(0, 0, 0))
            return node
        }

        private func keyLight() -> SCNNode {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = .omni
            node.light?.intensity = 850
            node.light?.temperature = 4_900
            node.position = SCNVector3(-2.2, 2.8, 3.2)
            return node
        }

        private func fillLight() -> SCNNode {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = .omni
            node.light?.intensity = 420
            node.light?.temperature = 6_500
            node.position = SCNVector3(2.4, 1.2, 2.2)
            return node
        }

        private func ambientLight() -> SCNNode {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = .ambient
            node.light?.intensity = 330
            return node
        }
    }
}

final class CatModelContainerView: UIView {
    let sceneView = SCNView()
    private let placeholder = UIImageView(image: UIImage(systemName: "pawprint.fill"))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private weak var modelRoot: SCNNode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.isPlaying = true
        sceneView.rendersContinuously = false
        sceneView.allowsCameraControl = false
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sceneView)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        pan.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(pan)

        placeholder.tintColor = UIColor.systemOrange.withAlphaComponent(0.26)
        placeholder.contentMode = .scaleAspectFit
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        spinner.color = .systemOrange
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 88),
            placeholder.heightAnchor.constraint(equalToConstant: 88),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 14),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "大橘的三维模型"
        accessibilityHint = "左右拖动可以让大橘水平转身"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setModelRoot(_ node: SCNNode) {
        modelRoot = node
    }

    @objc private func handleHorizontalPan(_ gesture: UIPanGestureRecognizer) {
        guard let modelRoot else { return }
        let translation = gesture.translation(in: sceneView)
        // SceneKit 的 Y 轴是模型的直立轴。只增量修改 yaw，位置、pitch、roll 始终不变。
        modelRoot.eulerAngles.y += Float(translation.x) * 0.012
        modelRoot.eulerAngles.x = 0
        modelRoot.eulerAngles.z = 0
        gesture.setTranslation(.zero, in: sceneView)
    }

    func setLoaded(_ loaded: Bool) {
        placeholder.isHidden = loaded
        spinner.isHidden = loaded
        if loaded { spinner.stopAnimating() }
    }
}
