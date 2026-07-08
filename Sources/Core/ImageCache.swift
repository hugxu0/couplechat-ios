import UIKit
import CryptoKit

// 全 App 共用的图片缓存：内存（NSCache）+ 磁盘（Caches/MediaCache）。
// 头像、聊天图片都走这里，避免每次滚动 / 进页面重复下载。
// 缓存管理页（设置 → 存储空间）直接读写这里的磁盘用量与清理接口。

final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    let directory: URL
    private let ioQueue = DispatchQueue(label: "image-cache-io", qos: .utility)

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

    /// 命中内存直接返回；否则在后台线程读磁盘 / 下载 + 解码（preparingForDisplay），
    /// 避免在滚动时于主线程解码大图造成掉帧。
    @discardableResult
    func image(for url: URL) async -> UIImage? {
        if let hit = memoryImage(for: url) { return hit }

        let file = fileURL(for: url)
        // 磁盘命中：后台读 + 解码
        if let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: file), let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }.value {
            memory.setObject(decoded, forKey: url.absoluteString as NSString)
            return decoded
        }

        // 网络：下载后仍在后台解码
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let prepared = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }.value
        guard let prepared else { return nil }
        memory.setObject(prepared, forKey: url.absoluteString as NSString)
        ioQueue.async { try? data.write(to: file) }
        return prepared
    }

    /// 已经拿到 Data（比如自己刚上传的图）时直接落缓存，省一次下载。
    func store(data: Data, image: UIImage? = nil, for url: URL) {
        let img = image ?? UIImage(data: data)
        if let img { memory.setObject(img, forKey: url.absoluteString as NSString) }
        let file = fileURL(for: url)
        ioQueue.async { try? data.write(to: file) }
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
}
