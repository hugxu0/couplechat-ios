import SwiftUI

// =============================================================
// 主题引擎：主题色 / 深浅模式 / 聊天壁纸。
// 单例 + EnvironmentObject 双身份：DS.Palette 的静态取值走单例，
// 视图层通过 environmentObject 订阅变化（改主题即全局刷新）。
// =============================================================

// MARK: - 主题色

enum AccentChoice: String, CaseIterable, Identifiable {
    case tangerine  // 蜜橘（默认）
    case sakura     // 樱粉
    case ocean      // 雾蓝
    case mint       // 薄荷
    case grape      // 葡萄

    var id: String { rawValue }

    var name: String {
        switch self {
        case .tangerine: return "蜜橘"
        case .sakura: return "樱粉"
        case .ocean: return "雾蓝"
        case .mint: return "薄荷"
        case .grape: return "葡萄"
        }
    }

    var color: Color {
        switch self {
        case .tangerine: return Color(red: 1.00, green: 0.45, blue: 0.20)
        case .sakura: return Color(red: 0.96, green: 0.36, blue: 0.55)
        case .ocean: return Color(red: 0.25, green: 0.52, blue: 0.95)
        case .mint: return Color(red: 0.10, green: 0.65, blue: 0.50)
        case .grape: return Color(red: 0.55, green: 0.38, blue: 0.92)
        }
    }

    /// 渐变的第二个颜色（比主色更暖/更深一点）
    var colorAlt: Color {
        switch self {
        case .tangerine: return Color(red: 1.00, green: 0.30, blue: 0.30)
        case .sakura: return Color(red: 0.90, green: 0.25, blue: 0.40)
        case .ocean: return Color(red: 0.40, green: 0.35, blue: 0.95)
        case .mint: return Color(red: 0.12, green: 0.55, blue: 0.65)
        case .grape: return Color(red: 0.75, green: 0.30, blue: 0.75)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [color, colorAlt], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - 深浅模式

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 聊天壁纸

enum WallpaperChoice: String, CaseIterable, Identifiable {
    case aurora     // 默认（粉紫黄柔光，即全局背景）
    case peach      // 蜜桃
    case mist       // 晨雾
    case cream      // 奶油
    case sky        // 天青
    case lavender   // 薰衣草
    case night      // 星夜（深色系）
    case plain      // 素色

    var id: String { rawValue }

    var name: String {
        switch self {
        case .aurora: return "默认"
        case .peach: return "蜜桃"
        case .mist: return "晨雾"
        case .cream: return "奶油"
        case .sky: return "天青"
        case .lavender: return "薰衣草"
        case .night: return "星夜"
        case .plain: return "素色"
        }
    }

    private var stops: [Color] {
        switch self {
        case .aurora:
            return [Color(red: 1.00, green: 0.93, blue: 0.93),
                    Color(red: 0.95, green: 0.91, blue: 0.98),
                    Color(red: 1.00, green: 0.97, blue: 0.88),
                    Color(red: 0.93, green: 0.95, blue: 1.00)]
        case .peach:
            return [Color(red: 1.00, green: 0.90, blue: 0.86),
                    Color(red: 1.00, green: 0.85, blue: 0.80),
                    Color(red: 0.99, green: 0.92, blue: 0.83)]
        case .mist:
            return [Color(red: 0.93, green: 0.95, blue: 0.97),
                    Color(red: 0.89, green: 0.93, blue: 0.96),
                    Color(red: 0.94, green: 0.93, blue: 0.98)]
        case .cream:
            return [Color(red: 1.00, green: 0.97, blue: 0.90),
                    Color(red: 0.99, green: 0.94, blue: 0.85),
                    Color(red: 1.00, green: 0.96, blue: 0.92)]
        case .sky:
            return [Color(red: 0.88, green: 0.94, blue: 1.00),
                    Color(red: 0.84, green: 0.92, blue: 0.99),
                    Color(red: 0.92, green: 0.96, blue: 1.00)]
        case .lavender:
            return [Color(red: 0.93, green: 0.90, blue: 0.99),
                    Color(red: 0.89, green: 0.87, blue: 0.98),
                    Color(red: 0.96, green: 0.92, blue: 0.99)]
        case .night:
            return [Color(red: 0.10, green: 0.11, blue: 0.20),
                    Color(red: 0.14, green: 0.12, blue: 0.26),
                    Color(red: 0.08, green: 0.10, blue: 0.16)]
        case .plain:
            return [Color(red: 0.96, green: 0.96, blue: 0.96),
                    Color(red: 0.94, green: 0.94, blue: 0.95)]
        }
    }

    /// 深色模式下自动压暗（星夜本身就是深色，不再压）。
    func gradient(dark: Bool) -> LinearGradient {
        let colors: [Color]
        if dark && self != .night {
            colors = stops.map { $0.opacity(0.16) }
        } else {
            colors = stops
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 壁纸选择器里的预览色带
    var previewGradient: LinearGradient {
        LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 印花装饰图案
    @ViewBuilder
    var patternOverlay: some View {
        let c = patternColor
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let s = min(w, h)
            switch self {
            case .aurora:
                // 柔光散布小星点
                ForEach(0..<28, id: \.self) { i in
                    let x = CGFloat((i * 73 + 17) % 100) / 100 * w
                    let y = CGFloat((i * 47 + 31) % 100) / 100 * h
                    Image(systemName: "sparkle")
                        .font(.system(size: s * 0.045))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .peach:
                // 蜜桃花瓣
                ForEach(0..<16, id: \.self) { i in
                    let x = CGFloat((i * 89 + 11) % 100) / 100 * w
                    let y = CGFloat((i * 55 + 23) % 100) / 100 * h
                    Image(systemName: "heart.fill")
                        .font(.system(size: s * 0.04))
                        .foregroundStyle(c)
                        .rotationEffect(.degrees(Double(i) * 41))
                        .position(x: x, y: y)
                }
            case .mist:
                ForEach(0..<10, id: \.self) { i in
                    let x = CGFloat((i * 67 + 5) % 100) / 100 * w
                    let y = CGFloat((i * 81 + 13) % 100) / 100 * h
                    Image(systemName: "circle.fill")
                        .font(.system(size: s * 0.18))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .cream:
                ForEach(0..<24, id: \.self) { i in
                    let x = CGFloat((i * 43 + 19) % 100) / 100 * w
                    let y = CGFloat((i * 61 + 7) % 100) / 100 * h
                    Circle()
                        .stroke(c, lineWidth: 1)
                        .frame(width: s * 0.06, height: s * 0.06)
                        .position(x: x, y: y)
                }
            case .sky:
                ForEach(0..<22, id: \.self) { i in
                    let x = CGFloat((i * 77 + 29) % 100) / 100 * w
                    let y = CGFloat((i * 53 + 17) % 100) / 100 * h
                    Image(systemName: "star.fill")
                        .font(.system(size: s * 0.038))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .lavender:
                ForEach(0..<18, id: \.self) { i in
                    let x = CGFloat((i * 71 + 13) % 100) / 100 * w
                    let y = CGFloat((i * 59 + 37) % 100) / 100 * h
                    Image(systemName: "leaf.fill")
                        .font(.system(size: s * 0.038))
                        .foregroundStyle(c)
                        .rotationEffect(.degrees(Double(i) * 57))
                        .position(x: x, y: y)
                }
            case .night:
                ForEach(0..<44, id: \.self) { i in
                    let x = CGFloat((i * 63 + 3) % 100) / 100 * w
                    let y = CGFloat((i * 41 + 11) % 100) / 100 * h
                    Image(systemName: "sparkle")
                        .font(.system(size: i % 5 == 0 ? s * 0.052 : s * 0.026))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .plain:
                ForEach(0..<16, id: \.self) { i in
                    let x = CGFloat((i * 59 + 7) % 100) / 100 * w
                    let y = CGFloat((i * 73 + 41) % 100) / 100 * h
                    Image(systemName: "diamond.fill")
                        .font(.system(size: s * 0.038))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            }
        }
    }

    private var patternColor: Color {
        switch self {
        case .aurora: return .white.opacity(0.30)
        case .peach: return Color(red: 0.95, green: 0.55, blue: 0.45).opacity(0.22)
        case .mist: return .white.opacity(0.35)
        case .cream: return Color(red: 0.90, green: 0.75, blue: 0.50).opacity(0.18)
        case .sky: return .white.opacity(0.30)
        case .lavender: return Color(red: 0.7, green: 0.55, blue: 0.95).opacity(0.22)
        case .night: return .white.opacity(0.28)
        case .plain: return Color(red: 0.80, green: 0.78, blue: 0.82).opacity(0.25)
        }
    }
}

// MARK: - ThemeManager

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var accent: AccentChoice {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "theme.accent") }
    }
    @Published var appearance: AppearanceChoice {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "theme.appearance") }
    }
    @Published private var wallpapers: [String: String] {
        didSet { UserDefaults.standard.set(wallpapers, forKey: "theme.wallpapers") }
    }
    @Published private var customWallpaperKeys: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(customWallpaperKeys), forKey: "theme.customWallpapers")
        }
    }

    private let customDir: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CustomWallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        accent = AccentChoice(rawValue: UserDefaults.standard.string(forKey: "theme.accent") ?? "") ?? .tangerine
        appearance = AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: "theme.appearance") ?? "") ?? .system
        wallpapers = UserDefaults.standard.dictionary(forKey: "theme.wallpapers") as? [String: String] ?? [:]
        customWallpaperKeys = Set(UserDefaults.standard.stringArray(forKey: "theme.customWallpapers") ?? [])
    }

    func wallpaper(for channel: ChatChannel) -> WallpaperChoice {
        WallpaperChoice(rawValue: wallpapers[channel.rawValue] ?? "") ?? .aurora
    }

    func setWallpaper(_ choice: WallpaperChoice, for channel: ChatChannel) {
        wallpapers[channel.rawValue] = choice.rawValue
    }

    func hasCustomWallpaper(for channel: ChatChannel) -> Bool {
        customWallpaperKeys.contains(channel.rawValue)
    }

    func customWallpaperImage(for channel: ChatChannel) -> UIImage? {
        let url = customDir.appendingPathComponent("\(channel.rawValue).jpg")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func setCustomWallpaper(imageData: Data, for channel: ChatChannel) {
        let url = customDir.appendingPathComponent("\(channel.rawValue).jpg")
        try? imageData.write(to: url, options: .atomic)
        customWallpaperKeys.insert(channel.rawValue)
    }

    func removeCustomWallpaper(for channel: ChatChannel) {
        let url = customDir.appendingPathComponent("\(channel.rawValue).jpg")
        try? FileManager.default.removeItem(at: url)
        customWallpaperKeys.remove(channel.rawValue)
    }
}
