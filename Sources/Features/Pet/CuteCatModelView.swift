import GLTFKit2
import SceneKit
import SwiftUI
import UIKit

/// 把用户提供的 GLB 模型放进原生 SceneKit 画布。加载失败时保留轻量占位，
/// 页面其他互动仍可使用，不让一个资源错误拖垮整个大橘页。
struct CuteCatModelView: UIViewRepresentable {
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
            case .stroke:
                action = .sequence([
                    .scale(to: 1.05, duration: 0.14),
                    .scale(to: 1, duration: 0.22),
                ])
            case .highFive:
                action = .sequence([
                    .moveBy(x: 0, y: 0.13, z: 0, duration: 0.16),
                    .moveBy(x: 0, y: -0.13, z: 0, duration: 0.22),
                ])
            case .teaser:
                action = .sequence([
                    .rotateBy(x: 0, y: 0.28, z: 0, duration: 0.14),
                    .rotateBy(x: 0, y: -0.56, z: 0, duration: 0.22),
                    .rotateBy(x: 0, y: 0.28, z: 0, duration: 0.16),
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
            let root = SCNNode()
            for child in loadedScene.rootNode.childNodes {
                root.addChildNode(child.clone())
            }
            normalize(root)
            presentationScene.rootNode.addChildNode(root)
            presentationScene.rootNode.addChildNode(cameraNode())
            presentationScene.rootNode.addChildNode(keyLight())
            presentationScene.rootNode.addChildNode(fillLight())
            presentationScene.rootNode.addChildNode(ambientLight())
            container.sceneView.scene = presentationScene
            container.setLoaded(true)
            modelRoot = root
        }

        private func normalize(_ node: SCNNode) {
            let (minimum, maximum) = node.boundingBox
            let width = maximum.x - minimum.x
            let height = maximum.y - minimum.y
            let depth = maximum.z - minimum.z
            let largest = max(width, max(height, depth))
            guard largest > 0 else { return }
            let scale = 2.2 / largest
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.isPlaying = true
        sceneView.rendersContinuously = false
        sceneView.allowsCameraControl = true
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sceneView)

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
        accessibilityHint = "单指拖动可以转动，双指可以缩放"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoaded(_ loaded: Bool) {
        placeholder.isHidden = loaded
        spinner.isHidden = loaded
        if loaded { spinner.stopAnimating() }
    }
}
