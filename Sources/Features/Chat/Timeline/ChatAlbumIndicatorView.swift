import PhotosUI
import UIKit

/// 合并图片消息的原生状态层。页码和 Live Photo 标识放进同一个
/// UIGlassContainerEffect，两个胶囊会按系统规则自然融合。
final class ChatAlbumIndicatorView: UIView {
    private let containerView: UIVisualEffectView
    private let pageHost: UIVisualEffectView
    private let liveHost: UIVisualEffectView
    private let stack = UIStackView()
    private let pageLabel = UILabel()
    private let liveImageView = UIImageView(
        image: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))

    override init(frame: CGRect) {
        let containerEffect = UIGlassContainerEffect()
        containerEffect.spacing = 7
        containerView = UIVisualEffectView(effect: containerEffect)
        pageHost = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        liveHost = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        super.init(frame: frame)

        isUserInteractionEnabled = false
        isAccessibilityElement = false
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        let containerContent = containerView.contentView
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        containerContent.addSubview(stack)

        configureHost(pageHost)
        configureHost(liveHost)
        stack.addArrangedSubview(liveHost)
        stack.addArrangedSubview(pageHost)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        pageLabel.textColor = .white
        pageLabel.textAlignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        hostContent(pageHost).addSubview(pageLabel)

        liveImageView.contentMode = .scaleAspectFit
        liveImageView.translatesAutoresizingMaskIntoConstraints = false
        hostContent(liveHost).addSubview(liveImageView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: containerContent.trailingAnchor),
            stack.topAnchor.constraint(equalTo: containerContent.topAnchor),
            stack.bottomAnchor.constraint(equalTo: containerContent.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: containerContent.leadingAnchor),
            pageHost.widthAnchor.constraint(equalToConstant: 48),
            pageHost.heightAnchor.constraint(equalToConstant: 24),
            liveHost.widthAnchor.constraint(equalToConstant: 34),
            liveHost.heightAnchor.constraint(equalToConstant: 24),
            pageLabel.leadingAnchor.constraint(equalTo: hostContent(pageHost).leadingAnchor, constant: 4),
            pageLabel.trailingAnchor.constraint(equalTo: hostContent(pageHost).trailingAnchor, constant: -4),
            pageLabel.topAnchor.constraint(equalTo: hostContent(pageHost).topAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: hostContent(pageHost).bottomAnchor),
            liveImageView.leadingAnchor.constraint(equalTo: hostContent(liveHost).leadingAnchor, constant: 3),
            liveImageView.trailingAnchor.constraint(equalTo: hostContent(liveHost).trailingAnchor, constant: -3),
            liveImageView.topAnchor.constraint(equalTo: hostContent(liveHost).topAnchor, constant: 2),
            liveImageView.bottomAnchor.constraint(equalTo: hostContent(liveHost).bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(page: Int, total: Int, isLivePhoto: Bool) {
        pageLabel.text = "\(page) / \(total)"
        liveHost.isHidden = !isLivePhoto
    }

    private func configureHost(_ view: UIVisualEffectView) {
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
    }

    private func hostContent(_ view: UIVisualEffectView) -> UIView {
        view.contentView
    }
}
