import SwiftUI
import UIKit

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
                // 极光：细密的星尘与微光
                ForEach(0..<64, id: \.self) { i in
                    let x = CGFloat((i * 73 + 17) % 100) / 100 * w
                    let y = CGFloat((i * 47 + 31) % 100) / 100 * h
                    Image(systemName: i % 7 == 0 ? "sparkles" : "circle.fill")
                        .font(.system(size: i % 7 == 0 ? s * 0.030 : s * 0.010))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .peach:
                // 蜜桃：飘落花瓣
                ForEach(0..<48, id: \.self) { i in
                    let x = CGFloat((i * 89 + 11) % 100) / 100 * w
                    let y = CGFloat((i * 55 + 23) % 100) / 100 * h
                    Image(systemName: "leaf.fill")
                        .font(.system(size: s * (i % 6 == 0 ? 0.036 : 0.018)))
                        .foregroundStyle(c)
                        .rotationEffect(.degrees(Double(i) * 41))
                        .position(x: x, y: y)
                }
            case .mist:
                // 晨雾：细小水汽叠成柔和雾团
                ForEach(0..<42, id: \.self) { i in
                    let x = CGFloat((i * 67 + 5) % 100) / 100 * w
                    let y = CGFloat((i * 81 + 13) % 100) / 100 * h
                    Image(systemName: "circle.fill")
                        .font(.system(size: s * (i % 5 == 0 ? 0.085 : 0.030)))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .cream:
                // 奶油：细腻的蕾丝圆点
                ForEach(0..<56, id: \.self) { i in
                    let x = CGFloat((i * 43 + 19) % 100) / 100 * w
                    let y = CGFloat((i * 61 + 7) % 100) / 100 * h
                    Circle()
                        .stroke(c, lineWidth: 1)
                        .frame(width: s * (i % 4 == 0 ? 0.050 : 0.025), height: s * (i % 4 == 0 ? 0.050 : 0.025))
                        .position(x: x, y: y)
                }
            case .sky:
                // 天青：风吹云纹
                ForEach(0..<44, id: \.self) { i in
                    let x = CGFloat((i * 77 + 29) % 100) / 100 * w
                    let y = CGFloat((i * 53 + 17) % 100) / 100 * h
                    Image(systemName: i % 5 == 0 ? "cloud.fill" : "circle.fill")
                        .font(.system(size: s * (i % 5 == 0 ? 0.040 : 0.012)))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .lavender:
                // 薰衣草：枝叶剪影
                ForEach(0..<50, id: \.self) { i in
                    let x = CGFloat((i * 71 + 13) % 100) / 100 * w
                    let y = CGFloat((i * 59 + 37) % 100) / 100 * h
                    Image(systemName: "leaf.fill")
                        .font(.system(size: s * (i % 6 == 0 ? 0.034 : 0.017)))
                        .foregroundStyle(c)
                        .rotationEffect(.degrees(Double(i) * 57))
                        .position(x: x, y: y)
                }
            case .night:
                // 星夜：密集远星，间或一颗亮星
                ForEach(0..<88, id: \.self) { i in
                    let x = CGFloat((i * 63 + 3) % 100) / 100 * w
                    let y = CGFloat((i * 41 + 11) % 100) / 100 * h
                    Image(systemName: i % 9 == 0 ? "sparkles" : (i % 4 == 0 ? "star.fill" : "circle.fill"))
                        .font(.system(size: i % 9 == 0 ? s * 0.038 : (i % 4 == 0 ? s * 0.018 : s * 0.007)))
                        .foregroundStyle(c)
                        .position(x: x, y: y)
                }
            case .plain:
                // 素色：克制的菱格点阵
                ForEach(0..<44, id: \.self) { i in
                    let x = CGFloat((i * 59 + 7) % 100) / 100 * w
                    let y = CGFloat((i * 73 + 41) % 100) / 100 * h
                    Image(systemName: "diamond.fill")
                        .font(.system(size: s * (i % 5 == 0 ? 0.022 : 0.010)))
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

/// 聊天界面需要分别判断顶栏与输入栏下方的壁纸明暗。
/// 不使用系统的深浅模式作为前景色依据，避免自定义壁纸和系统模式相互打架。
enum WallpaperSurfaceRegion: Hashable {
    case topCenter
    case composerCenter
}

/// 同一块玻璃面板只允许两种互斥组合：暗玻璃白字，或亮玻璃黑字。
/// 系统材质不会替应用完成局部壁纸采样，所以顶栏和输入栏都使用这一套阈值。
enum ChatSurfaceTone: Equatable {
    case lightContent
    case darkContent

    init(luminance: CGFloat) {
        self = luminance < 0.52 ? .lightContent : .darkContent
    }

    var usesLightContent: Bool { self == .lightContent }
    var usesDarkText: Bool { self == .darkContent }
}

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

    /// 自定义壁纸会在聊天视图频繁重绘时被读取。把解码和像素采样留在这里，
    /// 让转场与侧滑返回不再触发磁盘 I/O 和重复绘制。
    private var customWallpaperImageCache: [String: UIImage] = [:]
    private var customWallpaperLuminanceCache: [String: [WallpaperSurfaceRegion: CGFloat]] = [:]

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
        if let image = customWallpaperImageCache[channel.rawValue] {
            return image
        }
        let url = customDir.appendingPathComponent("\(channel.rawValue).jpg")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        customWallpaperImageCache[channel.rawValue] = image
        return image
    }

    func customWallpaperLuminance(for channel: ChatChannel, region: WallpaperSurfaceRegion) -> CGFloat? {
        let key = channel.rawValue
        if let cached = customWallpaperLuminanceCache[key]?[region] {
            return cached
        }
        guard let image = customWallpaperImage(for: channel) else { return nil }
        let value = Self.regionLuminance(of: image, region: region)
        customWallpaperLuminanceCache[key, default: [:]][region] = value
        return value
    }

    /// 输入栏会跟随键盘上下移动，因此不能一直采样壁纸底部；由 UIKit 传入它当前
    /// 胶囊在整屏中的位置，取样结果再驱动玻璃和文字的同一套互斥状态。
    func customWallpaperLuminance(for channel: ChatChannel, normalizedRect: CGRect) -> CGFloat? {
        guard let image = customWallpaperImage(for: channel) else { return nil }
        return Self.regionLuminance(of: image, normalizedRect: normalizedRect)
    }

    func setCustomWallpaper(imageData: Data, for channel: ChatChannel) {
        let url = customDir.appendingPathComponent("\(channel.rawValue).jpg")
        try? imageData.write(to: url, options: .atomic)
        if let image = UIImage(data: imageData) {
            customWallpaperImageCache[channel.rawValue] = image
        } else {
            customWallpaperImageCache[channel.rawValue] = nil
        }
        customWallpaperLuminanceCache[channel.rawValue] = nil
        customWallpaperKeys.insert(channel.rawValue)
    }

    func removeCustomWallpaper(for channel: ChatChannel) {
        let url = customDir.appendingPathComponent("\(channel.rawValue).jpg")
        try? FileManager.default.removeItem(at: url)
        customWallpaperImageCache[channel.rawValue] = nil
        customWallpaperLuminanceCache[channel.rawValue] = nil
        customWallpaperKeys.remove(channel.rawValue)
    }

    private static func regionLuminance(of image: UIImage, region: WallpaperSurfaceRegion) -> CGFloat {
        // 采样点要与实际控件位置对应：顶部标题在中间，输入胶囊也只看中间区域。
        // 整条边缘的天空、头像或消息不该干扰该控件的前景色决定。
        let sampleRect: CGRect
        switch region {
        case .topCenter:
            sampleRect = CGRect(x: 14.0 / 48.0, y: 7.0 / 104.0, width: 20.0 / 48.0, height: 12.0 / 104.0)
        case .composerCenter:
            sampleRect = CGRect(x: 7.0 / 48.0, y: 84.0 / 104.0, width: 34.0 / 48.0, height: 12.0 / 104.0)
        }
        return regionLuminance(of: image, normalizedRect: sampleRect)
    }

    private static func regionLuminance(of image: UIImage, normalizedRect: CGRect) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 0.7 }
        let pixelWidth = 48
        let pixelHeight = 104
        let renderSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let scale = max(renderSize.width / image.size.width, renderSize.height / image.size.height)
        let drawnSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: (renderSize.width - drawnSize.width) / 2,
            y: (renderSize.height - drawnSize.height) / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
        let normalized = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else { return 0.7 }
        let sampleRect = CGRect(
            x: floor(normalized.minX * renderSize.width),
            y: floor(normalized.minY * renderSize.height),
            width: max(1, ceil(normalized.width * renderSize.width)),
            height: max(1, ceil(normalized.height * renderSize.height))
        ).intersection(CGRect(origin: .zero, size: renderSize))
        guard sampleRect.width > 0, sampleRect.height > 0 else { return 0.7 }
        let sampleSize = CGSize(
            width: sampleRect.width,
            height: sampleRect.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let sampled = UIGraphicsImageRenderer(size: sampleSize, format: format).image { _ in
            image.draw(in: drawRect.offsetBy(dx: -sampleRect.minX, dy: -sampleRect.minY))
        }
        guard let sampledCGImage = sampled.cgImage else { return 0.7 }
        let sampleWidth = Int(sampleSize.width)
        let sampleHeight = Int(sampleSize.height)
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return 0.7 }
        context.draw(sampledCGImage, in: CGRect(origin: .zero, size: sampleSize))
        var luminances: [CGFloat] = []
        luminances.reserveCapacity(sampleWidth * sampleHeight)
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = CGFloat(pixels[index]) / 255
            let green = CGFloat(pixels[index + 1]) / 255
            let blue = CGFloat(pixels[index + 2]) / 255
            luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        }
        return luminances.sorted()[luminances.count / 2]
    }
}
