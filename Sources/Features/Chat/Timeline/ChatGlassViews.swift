import UIKit

/// 聊天控制层的原生 Liquid Glass 宿主。内容必须加入继承自
/// UIVisualEffectView 的 contentView，才能参与系统玻璃的自适应渲染。
final class ChatGlassView: UIVisualEffectView {
    init(
        style: UIGlassEffect.Style = .regular,
        cornerRadius: CGFloat,
        interactive: Bool = false
    ) {
        let glassEffect = UIGlassEffect(style: style)
        glassEffect.isInteractive = interactive
        super.init(effect: glassEffect)
        isOpaque = false
        backgroundColor = .clear
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        clipsToBounds = true
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

    func clearTint() {
        (effect as? UIGlassEffect)?.tintColor = nil
    }

    private func setSystemLiquidGlassTint(_ color: UIColor, alpha: CGFloat) {
        (effect as? UIGlassEffect)?.tintColor = alpha > 0 ? color.withAlphaComponent(alpha) : nil
    }
}
