import SwiftUI
import UIKit

// =============================================================
// 设计系统（Design Tokens）
// 全 App 的圆角、颜色、透明度、间距、动画曲线都只从这里取值。
// 主题色跟随 ThemeManager；明暗色用 UIColor 动态提供者自动适配深色模式。
// =============================================================

enum DS {

    // MARK: - 圆角
    enum Radius {
        /// 大卡片（首页情侣卡、记录页统计卡）
        static let card: CGFloat = 28
        /// 小卡片（互动按钮、状态格子）
        static let tile: CGFloat = 20
        /// 消息气泡
        static let bubble: CGFloat = 18
        /// 输入框、胶囊按钮
        static let pill: CGFloat = 999
        /// 底部标签栏
        static let tabBar: CGFloat = 32
    }

    // MARK: - 颜色
    enum Palette {
        /// 主题色（跟随「我的 → 外观」选择）
        static var accent: Color { ThemeManager.shared.accent.color }
        /// 主题渐变
        static var accentGradient: LinearGradient {
            LinearGradient(
                colors: [ThemeManager.shared.accent.color, ThemeManager.shared.accent.colorAlt],
                startPoint: .leading, endPoint: .trailing)
        }

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
        /// 卡片表面（白/深灰 半透明）
        static let cardSurface = adaptive(
            light: UIColor(white: 1, alpha: 0.72),
            dark: UIColor(white: 0.13, alpha: 0.78))
        /// 卡片内的次级表面（按钮底、图表槽）
        static let innerSurface = adaptive(
            light: UIColor(white: 1, alpha: 0.65),
            dark: UIColor(white: 0.22, alpha: 0.6))
        /// 悬浮控件底（标签栏、输入栏的非玻璃回退）
        static let floatSurface = adaptive(
            light: UIColor(white: 1, alpha: 0.80),
            dark: UIColor(white: 0.14, alpha: 0.86))
        /// 粉色点缀（心形、女生侧标签）
        static let pink = Color(red: 0.98, green: 0.35, blue: 0.55)
        /// 蓝色点缀（男生侧统计）
        static let blue = Color(red: 0.30, green: 0.55, blue: 0.95)
        /// 紫色点缀（共享区域标识）
        static let purple = Color(red: 0.58, green: 0.40, blue: 0.92)
        /// 成功 / 上升趋势
        static let green = Color(red: 0.15, green: 0.68, blue: 0.38)

        /// 成员专属色：小旭蓝、小偲粉（统计图/图例用）
        static func member(_ username: String) -> Color {
            username == "xu" ? blue : pink
        }
    }

    // MARK: - 表面材质
    enum Surface {
        /// 卡片阴影
        static let shadow = Color.black.opacity(0.06)
        static let shadowRadius: CGFloat = 14
        static let shadowY: CGFloat = 6
    }

    // MARK: - 间距
    enum Spacing {
        static let page: CGFloat = 16      // 页面左右留白
        static let card: CGFloat = 18      // 卡片内边距
        static let gap: CGFloat = 12       // 卡片之间
        static let bubbleGapSame: CGFloat = 3   // 同一人连续消息
        static let bubbleGapOther: CGFloat = 10 // 不同人之间
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
    }
}

// =============================================================
// 通用修饰符：卡片 / 按压回弹
// =============================================================

/// 统一卡片样式：半透明底 + 大圆角 + 轻阴影（深色模式自动换深底）
struct CardStyle: ViewModifier {
    var radius: CGFloat = DS.Radius.card
    func body(content: Content) -> some View {
        content
            .background(DS.Palette.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
    }
}

/// 按压时轻微缩小回弹（Telegram 手感的基础）
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(DS.Anim.springFast, value: configuration.isPressed)
    }
}

extension View {
    func dsCard(radius: CGFloat = DS.Radius.card) -> some View {
        modifier(CardStyle(radius: radius))
    }

    /// 悬浮控制层的统一材质：iOS 26 用系统液态玻璃（真折射、感知背后内容），
    /// 老系统退回半透明底。标签栏、输入栏等「浮在内容上的控件」都用这个。
    @ViewBuilder
    func dsGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(DS.Palette.floatSurface)
                .clipShape(shape)
                .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
        }
    }
}
