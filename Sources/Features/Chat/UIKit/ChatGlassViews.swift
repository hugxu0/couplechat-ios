import UIKit

final class ChatGlassView: UIView {
    private let blurView: UIVisualEffectView
    private let tintView = UIView()
    private let gradientLayer = CAGradientLayer()

    init(style: UIBlurEffect.Style = .systemThinMaterial, cornerRadius: CGFloat) {
        self.blurView = UIVisualEffectView(effect: Self.makeGlassEffect(fallback: style))
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        clipsToBounds = true

        blurView.isUserInteractionEnabled = false
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        tintView.isUserInteractionEnabled = false
        tintView.backgroundColor = UIColor.white.withAlphaComponent(0.04)
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)

        gradientLayer.colors = [
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.white.withAlphaComponent(0.03).cgColor,
            UIColor.black.withAlphaComponent(0.05).cgColor
        ]
        gradientLayer.locations = [0, 0.48, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradientLayer)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        layer.borderWidth = 0.6
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cornerRadius: CGFloat, tintAlpha: CGFloat = 0.04, borderAlpha: CGFloat = 0.10) {
        layer.cornerRadius = cornerRadius
        tintView.backgroundColor = UIColor.white.withAlphaComponent(tintAlpha)
        layer.borderColor = UIColor.white.withAlphaComponent(borderAlpha).cgColor
    }

    func setTintColor(_ color: UIColor, alpha: CGFloat) {
        tintView.backgroundColor = color.withAlphaComponent(alpha)
    }

    func setGradientAlpha(_ alpha: CGFloat) {
        gradientLayer.opacity = Float(alpha)
    }

    /// 原生模糊负责采样背景；根据背景选择深/浅玻璃以保持前景对比度。
    func setGlassTone(dark: Bool, tintAlpha: CGFloat, borderAlpha: CGFloat = 0.16) {
        let tint = dark ? UIColor.black : UIColor.white
        tintView.backgroundColor = tint.withAlphaComponent(tintAlpha)
        gradientLayer.colors = dark
            ? [
                UIColor.white.withAlphaComponent(0.10).cgColor,
                UIColor.black.withAlphaComponent(0.10).cgColor,
                UIColor.black.withAlphaComponent(0.28).cgColor
            ]
            : [
                UIColor.white.withAlphaComponent(0.20).cgColor,
                UIColor.white.withAlphaComponent(0.06).cgColor,
                UIColor.black.withAlphaComponent(0.05).cgColor
            ]
        layer.borderColor = UIColor.white.withAlphaComponent(borderAlpha).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        gradientLayer.cornerRadius = layer.cornerRadius
    }

    private static func makeGlassEffect(fallback: UIBlurEffect.Style) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect(style: .regular)
        }
        return UIBlurEffect(style: fallback)
    }
}

final class ChatGlassButton: UIButton {
    private let glassView: ChatGlassView

    init(symbolName: String, cornerRadius: CGFloat) {
        self.glassView = ChatGlassView(style: .systemThinMaterial, cornerRadius: cornerRadius)
        super.init(frame: .zero)
        backgroundColor = .clear
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        clipsToBounds = true
        setImage(UIImage(systemName: symbolName), for: .normal)
        imageView?.contentMode = .scaleAspectFit
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center

        glassView.isUserInteractionEnabled = false
        glassView.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(glassView, at: 0)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
                self.alpha = self.isHighlighted ? 0.82 : 1
            }
        }
    }

    func setGlassHidden(_ hidden: Bool) {
        glassView.isHidden = hidden
    }

    func updateGlass(cornerRadius: CGFloat, tintAlpha: CGFloat = 0.08, borderAlpha: CGFloat = 0.14) {
        layer.cornerRadius = cornerRadius
        glassView.update(cornerRadius: cornerRadius, tintAlpha: tintAlpha, borderAlpha: borderAlpha)
    }
}
