import UIKit

final class ChatGlassView: UIView {
    private let blurView: UIVisualEffectView

    init(cornerRadius: CGFloat) {
        self.blurView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        clipsToBounds = true

        blurView.isUserInteractionEnabled = false
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cornerRadius: CGFloat) {
        layer.cornerRadius = cornerRadius
    }

    func setTintColor(_ color: UIColor, alpha: CGFloat) {
        setSystemLiquidGlassTint(color, alpha: alpha)
    }

    /// 原生玻璃自行完成材质采样，只调整系统 tint，不叠加自定义高光层。
    func setGlassTone(dark: Bool, tintAlpha: CGFloat) {
        setSystemLiquidGlassTint(dark ? .black : .white, alpha: tintAlpha)
    }

    private func setSystemLiquidGlassTint(_ color: UIColor, alpha: CGFloat) {
        (blurView.effect as? UIGlassEffect)?.tintColor = alpha > 0 ? color.withAlphaComponent(alpha) : nil
    }
}
