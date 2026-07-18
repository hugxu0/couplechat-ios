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
    private let sizeLock = NSLock()
    private var imageSizes: [String: CGSize] = [:]
    private let inFlightLock = NSLock()
    private var inFlight: [String: (id: UUID, task: Task<UIImage?, Never>)] = [:]
    private let previewFailureLock = NSLock()
    private var previewFailures: [String: Date] = [:]
    private let fileManager = FileManager.default
    let directory: URL
    private let ioQueue = DispatchQueue(label: "image-cache-io", qos: .utility)
    private static let maxDownloadBytes: Int64 = 50 * 1024 * 1024
    private static let maxDiskBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let downloadGate = MediaDownloadGate(limit: 4)
    private static let cacheFormatMarker = ".stable-media-v2"
    private static let maxDecodedPixelSize = 2_400
    private static let maxAnimatedPixelSize = 600

    private init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("MediaCache", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        MediaCacheStorage.markDirectoryAsLocalCache(directory)
        let marker = directory.appendingPathComponent(Self.cacheFormatMarker)
        if !fileManager.fileExists(atPath: marker.path) {
            _ = fileManager.createFile(atPath: marker.path, contents: Data())
            ioQueue.async { [directory] in
                let items = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil)
                for item in items ?? [] where item.lastPathComponent != Self.cacheFormatMarker {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }
        memory.countLimit = 240
        ioQueue.async { [directory] in
            MediaCacheStorage.trim(directory: directory, maxBytes: Self.maxDiskBytes)
        }
    }

    /// 短期媒体签名每次刷新都会改变 sig/exp；缓存身份只忽略这两个授权参数，
    /// 路径（含 thumbnail）和其他查询参数仍参与缓存隔离。
    static func cacheIdentity(for url: URL) -> String {
        MediaCacheIdentity.value(for: url)
    }

    /// 用稳定媒体身份的 SHA256 十六进制做文件名：跨启动稳定，且不含非法字符。
    private func key(for url: URL) -> String {
        MediaCacheIdentity.digest(for: url)
    }

    private func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(key(for: url))
    }

    /// 仅查内存缓存（主线程安全、极快）。命中就不用走异步、也不闪占位。
    func memoryImage(for url: URL) -> UIImage? {
        memory.object(forKey: Self.cacheIdentity(for: url) as NSString)
    }

    /// 图片解码后的尺寸独立于 NSCache 保存。系统在后台可能清理已解码图片，
    /// 但聊天气泡的布局尺寸不能因此退回默认占位高度。
    func imageSize(for url: URL) -> CGSize? {
        if let image = memoryImage(for: url) { return image.size }
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return imageSizes[Self.cacheIdentity(for: url)]
    }

    func rememberImageSize(_ size: CGSize, for url: URL) {
        guard size.width > 0, size.height > 0 else { return }
        sizeLock.lock()
        imageSizes[Self.cacheIdentity(for: url)] = size
        sizeLock.unlock()
    }

    func isCached(_ url: URL) -> Bool {
        if memory.object(forKey: Self.cacheIdentity(for: url) as NSString) != nil { return true }
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
            ioQueue.async { MediaCacheStorage.touch(file) }
            storeInMemory(decoded, for: url)
        }
        return decoded
    }

    /// 命中内存直接返回；否则在后台线程读磁盘 / 下载 + 解码（preparingForDisplay），
    /// 避免在滚动时于主线程解码大图造成掉帧。
    @discardableResult
    func image(for url: URL) async -> UIImage? {
        if let hit = memoryImage(for: url) { return hit }
        let identity = Self.cacheIdentity(for: url)
        let entry = inFlightLock.withLock {
            if let existing = inFlight[identity] {
                return existing
            }
            let id = UUID()
            let task = Task { [weak self] in
                await self?.loadImage(for: url)
            }
            let entry = (id: id, task: task)
            inFlight[identity] = entry
            return entry
        }

        let result = await entry.task.value
        inFlightLock.withLock {
            if inFlight[identity]?.id == entry.id {
                inFlight.removeValue(forKey: identity)
            }
        }
        return result
    }

    private func loadImage(for url: URL) async -> UIImage? {
        // 自己刚选中的照片在消息确认前使用 file:// 临时地址。它不能交给 URLSession，
        // 直接后台解码才能让点开本人刚发的图立即看到原图。
        if url.isFileURL {
            let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return Self.decodeForDisplay(data)
            }.value
            guard !Task.isCancelled else { return nil }
            if let decoded {
                storeInMemory(decoded, for: url)
            }
            return decoded
        }

        let file = fileURL(for: url)
        // 磁盘命中：后台读 + 解码
        if let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return Self.decodeForDisplay(data)
        }.value {
            guard !Task.isCancelled else { return nil }
            ioQueue.async { MediaCacheStorage.touch(file) }
            storeInMemory(decoded, for: url)
            return decoded
        }

        // 网络：下载后仍在后台解码
        guard let data = await downloadImageData(for: url) else { return nil }
        let prepared = await Task.detached(priority: .utility) { () -> UIImage? in
            Self.decodeForDisplay(data)
        }.value
        guard let prepared, !Task.isCancelled else { return nil }
        storeInMemory(prepared, for: url)
        ioQueue.async {
            do {
                try data.write(to: file)
                MediaCacheStorage.protect(file)
                MediaCacheStorage.touch(file)
                MediaCacheStorage.trim(
                    directory: self.directory,
                    maxBytes: Self.maxDiskBytes,
                    preserving: [file])
            } catch {
                print("[ImageCache] ⚠️ 磁盘写入失败 url=\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return prepared
    }

    /// 气泡优先读取已落盘原图，其次读取上传时生成的小图；服务端或历史资源
    /// 没有缩略图时回退原图，并短暂记住失败，避免滚动复用反复请求同一个 404。
    func previewImage(for originalURL: URL, thumbnailURL: URL?) async -> UIImage? {
        if let original = await cachedImage(for: originalURL) { return original }
        guard let thumbnailURL else { return await image(for: originalURL) }
        if let thumbnail = await cachedImage(for: thumbnailURL) { return thumbnail }
        let thumbnailIdentity = Self.cacheIdentity(for: thumbnailURL)
        let failedRecently = previewFailureLock.withLock {
            previewFailures[thumbnailIdentity].map {
                Date().timeIntervalSince($0) < 5 * 60
            } ?? false
        }
        if !failedRecently {
            if let thumbnail = await image(for: thumbnailURL) {
                previewFailureLock.withLock {
                    previewFailures.removeValue(forKey: thumbnailIdentity)
                }
                return thumbnail
            }
            previewFailureLock.withLock {
                previewFailures[thumbnailIdentity] = Date()
            }
        }
        return await image(for: originalURL)
    }

    private func downloadImageData(for url: URL) async -> Data? {
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            do {
                let (data, response) = try await Self.downloadData(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if (200..<300).contains(http.statusCode),
                   Int64(data.count) <= Self.maxDownloadBytes {
                    return data
                }
                // 签名或资源本身无效，重复请求不会恢复。
                if (400..<500).contains(http.statusCode) { return nil }
            } catch {
                guard !Task.isCancelled else { return nil }
            }
            if attempt == 0 {
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        return nil
    }

    private static func downloadData(for request: URLRequest) async throws -> (Data, URLResponse) {
        await downloadGate.acquire()
        do {
            let result = try await URLSession.shared.data(for: request)
            await downloadGate.release()
            return result
        } catch {
            await downloadGate.release()
            throw error
        }
    }

    /// 已经拿到 Data（比如自己刚上传的图）时直接落缓存，省一次下载。
    func store(data: Data, image: UIImage? = nil, for url: URL) {
        let file = fileURL(for: url)
        if let image {
            storeInMemory(image, for: url)
        }
        ioQueue.async {
            if image == nil, let decoded = Self.decodeForDisplay(data) {
                self.storeInMemory(decoded, for: url)
            }
            do {
                try data.write(to: file)
                MediaCacheStorage.protect(file)
                MediaCacheStorage.touch(file)
                MediaCacheStorage.trim(
                    directory: self.directory,
                    maxBytes: Self.maxDiskBytes,
                    preserving: [file])
            } catch {
                print("[ImageCache] ⚠️ 磁盘写入失败 url=\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// 撤回媒体时同时清理原资源、图片缩略图与视频封面使用的合成缓存键。
    func removeMedia(for url: URL) async {
        await remove(for: url)
        if let thumbnailURL = ServerConfig.mediaThumbnailURL(for: url) {
            await remove(for: thumbnailURL)
        }
        let digest = SHA256.hash(data: Data(Self.cacheIdentity(for: url).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if let thumbnailURL = URL(string: "cc-video-thumbnail://cache/\(digest)") {
            await remove(for: thumbnailURL)
        }
    }

    private func remove(for url: URL) async {
        let identity = Self.cacheIdentity(for: url)
        memory.removeObject(forKey: identity as NSString)
        sizeLock.lock()
        imageSizes.removeValue(forKey: identity)
        sizeLock.unlock()
        previewFailureLock.lock()
        previewFailures.removeValue(forKey: identity)
        previewFailureLock.unlock()
        inFlightLock.lock()
        let task = inFlight.removeValue(forKey: identity)?.task
        inFlightLock.unlock()
        task?.cancel()
        if let task { _ = await task.value }
        let file = fileURL(for: url)
        await withCheckedContinuation { continuation in
            ioQueue.async { [fileManager] in
                if fileManager.fileExists(atPath: file.path) {
                    try? fileManager.removeItem(at: file)
                }
                continuation.resume()
            }
        }
    }

    // MARK: - 缓存管理（供存储空间页使用）

    /// 磁盘缓存总字节数
    func diskUsageBytes() -> Int64 {
        MediaCacheStorage.stats(at: directory).bytes
    }

    /// 已缓存的文件数量
    func cachedFileCount() -> Int {
        MediaCacheStorage.stats(at: directory).fileCount
    }

    func clearAllAsync() async {
        let tasks = clearMemoryAndTasks()
        for task in tasks {
            _ = await task.value
        }
        await withCheckedContinuation { continuation in
            ioQueue.async { [directory] in
                MediaCacheStorage.removeContents(of: directory)
                Self.createCacheFormatMarker(in: directory)
                continuation.resume()
            }
        }
    }

    private func clearMemoryAndTasks() -> [Task<UIImage?, Never>] {
        memory.removeAllObjects()
        sizeLock.lock()
        imageSizes.removeAll()
        sizeLock.unlock()
        previewFailureLock.lock()
        previewFailures.removeAll()
        previewFailureLock.unlock()
        inFlightLock.lock()
        let tasks = inFlight.values.map { $0.task }
        inFlight.removeAll()
        inFlightLock.unlock()
        tasks.forEach { $0.cancel() }
        return tasks
    }

    private static func createCacheFormatMarker(in directory: URL) {
        let marker = directory.appendingPathComponent(cacheFormatMarker)
        _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
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

    private func storeInMemory(_ image: UIImage, for url: URL) {
        memory.setObject(image, forKey: Self.cacheIdentity(for: url) as NSString)
        rememberImageSize(image.size, for: url)
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
        if duration <= 0 { duration = Double(count) * 0.1 }
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
