import UIKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// 全 App 共用的图片缓存：内存（NSCache）+ 磁盘（Caches/MediaCache）。
// 头像、聊天图片都走这里，避免每次滚动 / 进页面重复下载。
// 缓存管理页（设置 → 存储空间）直接读写这里的磁盘用量与清理接口。

final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    let directory: URL
    private let ioQueue = DispatchQueue(label: "image-cache-io", qos: .utility)
    private static let maxDownloadBytes: Int64 = 50 * 1024 * 1024
    private static let maxDecodedPixelSize = 2_400
    private static let maxAnimatedPixelSize = 600

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MediaCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 240
    }

    /// 用 url 的 SHA256 十六进制做文件名：跨启动稳定，且不含非法字符。
    private func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(key(for: url))
    }

    /// 仅查内存缓存（主线程安全、极快）。命中就不用走异步、也不闪占位。
    func memoryImage(for url: URL) -> UIImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    func isCached(_ url: URL) -> Bool {
        if memory.object(forKey: url.absoluteString as NSString) != nil { return true }
        return fileManager.fileExists(atPath: fileURL(for: url).path)
    }

    /// 只读取现有缓存，不在未命中时发起网络请求。视频封面使用合成 key，
    /// 需要复用图片缓存的内存和磁盘能力，但不能把合成 URL 当成远程资源下载。
    func cachedImage(for url: URL) async -> UIImage? {
        if let hit = memoryImage(for: url) { return hit }
        let file = fileURL(for: url)
        let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return Self.decodeForDisplay(data)
        }.value
        if let decoded {
            memory.setObject(decoded, forKey: url.absoluteString as NSString)
        }
        return decoded
    }

    /// 命中内存直接返回；否则在后台线程读磁盘 / 下载 + 解码（preparingForDisplay），
    /// 避免在滚动时于主线程解码大图造成掉帧。
    @discardableResult
    func image(for url: URL) async -> UIImage? {
        if let hit = memoryImage(for: url) { return hit }

        // 自己刚选中的照片在消息确认前使用 file:// 临时地址。它不能交给 URLSession，
        // 直接后台解码才能让点开本人刚发的图立即看到原图。
        if url.isFileURL {
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return Self.decodeForDisplay(data)
            }.value
            if let decoded {
                memory.setObject(decoded, forKey: url.absoluteString as NSString)
            }
            return decoded
        }

        let file = fileURL(for: url)
        // 磁盘命中：后台读 + 解码
        if let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return Self.decodeForDisplay(data)
        }.value {
            memory.setObject(decoded, forKey: url.absoluteString as NSString)
            return decoded
        }

        // 网络：下载后仍在后台解码
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              Int64(data.count) <= Self.maxDownloadBytes else { return nil }
        let prepared = await Task.detached(priority: .utility) { () -> UIImage? in
            Self.decodeForDisplay(data)
        }.value
        guard let prepared else { return nil }
        memory.setObject(prepared, forKey: url.absoluteString as NSString)
        ioQueue.async {
            do {
                try data.write(to: file)
            } catch {
                print("[ImageCache] ⚠️ 磁盘写入失败 url=\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return prepared
    }

    /// 已经拿到 Data（比如自己刚上传的图）时直接落缓存，省一次下载。
    func store(data: Data, image: UIImage? = nil, for url: URL) {
        let file = fileURL(for: url)
        if let image {
            memory.setObject(image, forKey: url.absoluteString as NSString)
        }
        ioQueue.async { [memory] in
            if image == nil, let decoded = Self.decodeForDisplay(data) {
                memory.setObject(decoded, forKey: url.absoluteString as NSString)
            }
            do {
                try data.write(to: file)
            } catch {
                print("[ImageCache] ⚠️ 磁盘写入失败 url=\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// 撤回媒体时同时清理原资源与视频封面使用的合成缓存键。
    func removeMedia(for url: URL) {
        remove(for: url)
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if let thumbnailURL = URL(string: "cc-video-thumbnail://cache/\(digest)") {
            remove(for: thumbnailURL)
        }
    }

    func remove(for url: URL) {
        memory.removeObject(forKey: url.absoluteString as NSString)
        let file = fileURL(for: url)
        ioQueue.async { [fileManager] in
            guard fileManager.fileExists(atPath: file.path) else { return }
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - 缓存管理（供存储空间页使用）

    /// 磁盘缓存总字节数
    func diskUsageBytes() -> Int64 {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
    }

    /// 已缓存的文件数量
    func cachedFileCount() -> Int {
        (try? fileManager.contentsOfDirectory(atPath: directory.path))?.count ?? 0
    }

    /// 清空全部图片缓存（内存 + 磁盘）
    func clearAll() {
        memory.removeAllObjects()
        ioQueue.async { [fileManager, directory] in
            guard let items = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
            for name in items {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    private static func decodeForDisplay(_ data: Data) -> UIImage? {
        guard Int64(data.count) <= maxDownloadBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if isAnimatedSource(source),
           let animated = decodeAnimatedImage(source) {
            return animated
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodedPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage).preparingForDisplay() ?? UIImage(cgImage: cgImage)
    }

    private static func isAnimatedSource(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String) else { return false }
        // HEIC 也可能包含深度图等多个 image item，但它们不是逐帧动画。
        return type.conforms(to: .gif) || type == .png || type == .webP
    }

    /// Preserve animated GIF/APNG data as an animated UIImage. The disk cache always stores the
    /// untouched bytes; frames are downsampled only for the in-memory rendering copy so a large
    /// sticker cannot exhaust memory while scrolling.
    private static func decodeAnimatedImage(_ source: CGImageSource) -> UIImage? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let pixelBudget = 2_000_000.0 // roughly 8 MB of decoded BGRA frames
        let budgetedPixelSize = Int(sqrt(pixelBudget / Double(count)))
        let maxPixelSize = min(maxAnimatedPixelSize, max(160, budgetedPixelSize))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [UIImage] = []
        frames.reserveCapacity(count)
        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary) else { return nil }
            frames.append(UIImage(cgImage: cgImage))
            duration += frameDuration(source: source, index: index)
        }
        guard duration > 0 else { duration = Double(count) * 0.1 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let value = unclamped ?? clamped ?? 0.1
        // Very small delays are commonly encoder placeholders and render too fast on iOS.
        return value < 0.02 ? 0.1 : value
    }
}
