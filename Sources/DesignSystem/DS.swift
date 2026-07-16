import SwiftUI
import UIKit

// =============================================================
// 设计系统（Design Tokens）
// 全 App 的圆角、颜色、间距、字体、动画、材质都只从这里取值。
// 主题色跟随 ThemeManager；明暗色用 UIColor 动态提供者自动适配深色模式。
// =============================================================

enum DS {

    // MARK: - 圆角
    enum Radius {
        /// 大卡片（首页情侣卡、记录页统计卡）
        static let card: CGFloat = 30
        /// 中卡片 / sheet 内块
        static let panel: CGFloat = 24
        /// 小卡片（互动按钮、状态格子）
        static let tile: CGFloat = 20
        /// 消息气泡
        static let bubble: CGFloat = 18
        /// 表单控件、次级按钮
        static let control: CGFloat = 14
        /// 状态条、小标签
        static let chip: CGFloat = 10
    }

    // MARK: - 颜色
    enum Palette {
        /// 主题色（跟随「我的 → 外观」选择）
        static var accent: Color { ThemeManager.shared.accent.color }
        /// 明暗自适应颜色的便捷构造
        private static func adaptive(light: UIColor, dark: UIColor) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }

        /// 对方气泡底色
        static let bubbleOther = adaptive(
            light: .white,
            dark: UIColor(white: 0.16, alpha: 1))
        /// 页面背景的柔和多彩渐变（深色模式换成深夜色）
        static var bgGradient: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: adaptive(light: UIColor(red: 1.00, green: 0.93, blue: 0.93, alpha: 1),
                                          dark: UIColor(red: 0.09, green: 0.08, blue: 0.12, alpha: 1)), location: 0.0),
                    .init(color: adaptive(light: UIColor(red: 0.95, green: 0.91, blue: 0.98, alpha: 1),
                                          dark: UIColor(red: 0.11, green: 0.09, blue: 0.16, alpha: 1)), location: 0.35),
                    .init(color: adaptive(light: UIColor(red: 1.00, green: 0.97, blue: 0.88, alpha: 1),
                                          dark: UIColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1)), location: 0.7),
                    .init(color: adaptive(light: UIColor(red: 0.93, green: 0.95, blue: 1.00, alpha: 1),
                                          dark: UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)), location: 1.0),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        /// 主要文字
        static let textPrimary = adaptive(
            light: UIColor(red: 0.20, green: 0.16, blue: 0.15, alpha: 1),
            dark: UIColor(white: 0.93, alpha: 1))
        /// 次要文字（时间戳、副标题）
        static let textSecondary = adaptive(
            light: UIColor(red: 0.55, green: 0.50, blue: 0.48, alpha: 1),
            dark: UIColor(white: 0.62, alpha: 1))
        /// 三级文字（占位、弱提示）
        static let textTertiary = adaptive(
            light: UIColor(red: 0.66, green: 0.62, blue: 0.60, alpha: 1),
            dark: UIColor(white: 0.48, alpha: 1))
        /// 卡片表面（白/深灰 半透明）
        static let cardSurface = adaptive(
            light: UIColor(white: 1, alpha: 0.72),
            dark: UIColor(white: 0.13, alpha: 0.78))
        /// 卡片内的次级表面（按钮底、图表槽）
        static let innerSurface = adaptive(
            light: UIColor(white: 1, alpha: 0.65),
            dark: UIColor(white: 0.22, alpha: 0.6))
        /// 表单字段底（登录密码框等，比卡片略实一点）
        static let fieldSurface = adaptive(
            light: UIColor(white: 1, alpha: 0.88),
            dark: UIColor(white: 0.18, alpha: 0.92))
        /// 细描边
        static let hairline = Color.primary.opacity(0.06)
        /// 粉色点缀（心形、女生侧标签）
        static let pink = Color(red: 0.98, green: 0.35, blue: 0.55)
        /// 蓝色点缀（男生侧统计）
        static let blue = Color(red: 0.30, green: 0.55, blue: 0.95)
        /// 紫色点缀（共享区域标识）
        static let purple = Color(red: 0.58, green: 0.40, blue: 0.92)
        /// 成功 / 上升趋势
        static let green = Color(red: 0.15, green: 0.68, blue: 0.38)
        /// 警告
        static let orange = Color(red: 0.95, green: 0.55, blue: 0.18)
        /// 危险 / 错误
        static let red = Color(red: 0.92, green: 0.28, blue: 0.30)

        /// 成员专属色：小旭蓝、小偲粉（统计图/图例用）
        static func member(_ username: String) -> Color {
            username == "xu" ? blue : pink
        }
    }

    // MARK: - 表面材质 / 阴影
    enum Surface {
        static let shadow = Color.black.opacity(0.06)
        static let shadowRadius: CGFloat = 14
        static let shadowY: CGFloat = 6
        static let softShadowRadius: CGFloat = 10
        static let softShadowY: CGFloat = 4
    }

    // MARK: - 间距
    enum Spacing {
        static let page: CGFloat = 16      // 页面左右留白
        static let card: CGFloat = 18      // 卡片内边距
        static let gap: CGFloat = 12       // 卡片之间
        static let section: CGFloat = 20   // 区块之间
        static let compact: CGFloat = 8    // 紧凑组内
        static let tight: CGFloat = 4
        static let bubbleGapSame: CGFloat = 3   // 同一人连续消息
        static let bubbleGapOther: CGFloat = 10 // 不同人之间
        static let controlVertical: CGFloat = 14
        static let fieldHorizontal: CGFloat = 16
        static let fieldVertical: CGFloat = 12
    }

    // MARK: - 字体（优先系统 Text Style；大数字/底栏保留固定档）
    enum Typo {
        /// 登录大标题等展示用
        static let display = Font.system(.largeTitle, design: .rounded).weight(.bold)
        /// 次级大数字（存储总量、统计卡标题数）
        static let displayNumber = Font.system(size: 26, weight: .heavy, design: .rounded)
        /// 根页标题
        static let pageTitle = Font.title2.weight(.bold)
        /// 卡片主标题
        static let cardTitle = Font.headline.weight(.bold)
        /// 正文
        static let body = Font.body
        /// 次要说明
        static let secondary = Font.subheadline
        /// 更弱说明 / 时间
        static let caption = Font.caption
        /// 分区小标签（卡片内「主题色」「预览」等）
        static let sectionLabel = Font.system(size: 13, weight: .semibold)
        /// 最小标签（色名、底栏旁注）
        static let micro = Font.system(size: 11, weight: .medium)
        /// 按钮主文案
        static let button = Font.system(.body, design: .default).weight(.semibold)
        /// Tab 标签（底栏空间有限，固定档）
        static let tab = Font.system(size: 11, weight: .medium)
    }

    // MARK: - 动画（手感统一从这里取）
    enum Anim {
        /// 标准弹簧：页面元素出现、选中切换
        static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
        /// 快速弹簧：按钮按压回弹、小元素
        static let springFast = Animation.spring(response: 0.28, dampingFraction: 0.75)
        /// 消息入场
        static let message = Animation.spring(response: 0.42, dampingFraction: 0.80)
        /// 普通淡入淡出
        static let ease = Animation.easeOut(duration: 0.22)

        /// 尊重系统「减少动态效果」
        static func motion(_ animation: Animation) -> Animation? {
            UIAccessibility.isReduceMotionEnabled ? nil : animation
        }

        static func withMotion(_ animation: Animation, _ body: () -> Void) {
            if UIAccessibility.isReduceMotionEnabled {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, body)
            } else {
                withAnimation(animation, body)
            }
        }
    }

}

// =============================================================
// 通用修饰符：卡片 / 按压回弹 / 玻璃
// =============================================================

/// 统一内容卡片：半透明 soft surface + 大圆角 + 轻阴影
struct CardStyle: ViewModifier {
    var radius: CGFloat = DS.Radius.card
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background(DS.Palette.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DS.Palette.hairline, lineWidth: 0.5)
            }
            .shadow(
                color: elevated ? DS.Surface.shadow : .clear,
                radius: elevated ? DS.Surface.shadowRadius : 0,
                y: elevated ? DS.Surface.shadowY : 0)
    }
}

/// 按压时轻微缩小回弹
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !UIAccessibility.isReduceMotionEnabled ? 0.96 : 1.0)
            .animation(DS.Anim.motion(DS.Anim.springFast), value: configuration.isPressed)
    }
}

extension View {
    /// 主内容卡片（渐变背景上的 soft glass card）
    func dsCard(radius: CGFloat = DS.Radius.card, elevated: Bool = true) -> some View {
        modifier(CardStyle(radius: radius, elevated: elevated))
    }

    /// 可交互液态玻璃：圆形小按钮用
    @ViewBuilder
    func dsGlassInteractive<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.ultraThinMaterial)
                .clipShape(shape)
                .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
        }
    }
}
