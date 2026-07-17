import UIKit

final class ChatGlassView: UIView {
    private let blurView: UIVisualEffectView
    private let toneOverlayView = UIView()

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
        toneOverlayView.isUserInteractionEnabled = false
        toneOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toneOverlayView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            toneOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toneOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toneOverlayView.topAnchor.constraint(equalTo: topAnchor),
            toneOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(cornerRadius: CGFloat) {
        layer.cornerRadius = cornerRadius
    }

    func setTintColor(_ color: UIColor, alpha: CGFloat) {
        toneOverlayView.backgroundColor = .clear
        setSystemLiquidGlassTint(color, alpha: alpha)
    }

    /// 原生玻璃自行完成材质采样，只调整系统 tint，不叠加自定义高光层。
    func setGlassTone(dark: Bool, tintAlpha: CGFloat) {
        toneOverlayView.backgroundColor = .clear
        setSystemLiquidGlassTint(dark ? .black : .white, alpha: tintAlpha)
    }

    /// 聊天控件需要在同一张明暗混合壁纸上保持一致，统一色层会削弱各自位置
    /// 的局部采样差异，同时保留系统液态玻璃的模糊与折射。
    func setStableGlassTone(dark: Bool, overlayAlpha: CGFloat) {
        let tone: UIColor = dark ? .black : .white
        setSystemLiquidGlassTint(tone, alpha: 0.12)
        toneOverlayView.backgroundColor = tone.withAlphaComponent(overlayAlpha)
    }

    private func setSystemLiquidGlassTint(_ color: UIColor, alpha: CGFloat) {
        (blurView.effect as? UIGlassEffect)?.tintColor = alpha > 0 ? color.withAlphaComponent(alpha) : nil
    }
}
