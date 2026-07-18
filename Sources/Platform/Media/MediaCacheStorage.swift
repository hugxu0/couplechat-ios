import CryptoKit
import Foundation

struct MediaCacheStats: Equatable, Sendable {
    let bytes: Int64
    let fileCount: Int

    static let empty = MediaCacheStats(bytes: 0, fileCount: 0)
}

actor MediaDownloadGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

/// 媒体签名会定期刷新；本地身份只忽略受控媒体路由的授权参数。
/// host、path（包含 thumbnail 变体）和其他查询参数仍参与隔离。
enum MediaCacheIdentity {
    static func value(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        let isSignedMedia = (pathParts.count == 2 || pathParts.count == 3)
            && pathParts[0] == "media"
            && pathParts[1].hasPrefix("up_")
            && (pathParts.count == 2 || pathParts[2] == "thumbnail")
        guard isSignedMedia else { return url.absoluteString }
        components.queryItems = components.queryItems?.filter {
            $0.name != "sig" && $0.name != "exp"
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    static func digest(for url: URL) -> String {
        let hash = SHA256.hash(data: Data(value(for: url).utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// 图片、语音和文件预览共同使用的磁盘维护原语。访问时间复用修改时间，
/// 不额外维护数据库；缓存本身不是事实源，损坏或被系统删除后都可重新下载。
enum MediaCacheStorage {
    static func stats(at directory: URL) -> MediaCacheStats {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return .empty }

        var bytes: Int64 = 0
        var fileCount = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            fileCount += 1
        }
        return MediaCacheStats(bytes: bytes, fileCount: fileCount)
    }

    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path)
    }

    static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }

    static func removeContents(of directory: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// 超过硬上限后回收到 85%，减少每次写入都触发淘汰的抖动。
    static func trim(
        directory: URL,
        maxBytes: Int64,
        preserving protectedURLs: Set<URL> = []
    ) {
        struct Entry {
            let url: URL
            let size: Int64
            let modifiedAt: Date
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let protected = Set(protectedURLs.map(\.standardizedFileURL))
        var entries: [Entry] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            entries.append(Entry(
                url: url,
                size: size,
                modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        guard totalBytes > maxBytes else { return }

        let targetBytes = Int64(Double(maxBytes) * 0.85)
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt })
            where totalBytes > targetBytes {
            guard !protected.contains(entry.url.standardizedFileURL) else { continue }
            do {
                try FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.size
            } catch {
                continue
            }
        }
        removeEmptyDirectories(in: directory)
    }

    static func markDirectoryAsLocalCache(_ directory: URL) {
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(values)
        protect(directory)
    }

    private static func removeEmptyDirectories(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                directories.append(url)
            }
        }
        for url in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
               contents.isEmpty {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
