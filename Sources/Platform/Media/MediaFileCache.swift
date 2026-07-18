import Foundation

enum DownloadedMediaKind: String, CaseIterable, Sendable {
    case voice
    case file

    var directoryName: String {
        switch self {
        case .voice: "VoiceMedia"
        case .file: "FilePreviews"
        }
    }

    var maxBytes: Int64 {
        switch self {
        case .voice: 256 * 1_024 * 1_024
        case .file: 512 * 1_024 * 1_024
        }
    }
}

struct DownloadedMediaCacheStats: Equatable, Sendable {
    let voice: MediaCacheStats
    let files: MediaCacheStats
}

enum MediaFileCacheError: LocalizedError {
    case invalidResponse
    case emptyFile
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "媒体下载失败"
        case .emptyFile: "媒体文件为空"
        case .fileTooLarge: "媒体文件超过本地缓存限制"
        }
    }
}

/// 语音和文件预览的统一落盘边界：稳定 key、请求合并、原子发布、文件保护和 LRU。
actor MediaFileCache {
    static let shared = MediaFileCache()

    private let startupMaintenance: Task<Void, Never>
    private var inFlight: [String: (id: UUID, task: Task<URL, Error>)] = [:]

    private init() {
        startupMaintenance = Task.detached(priority: .background) {
            for kind in DownloadedMediaKind.allCases {
                let root = MediaFileCacheIO.rootDirectory(for: kind)
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                MediaCacheStorage.markDirectoryAsLocalCache(root)
                MediaFileCacheIO.removeLegacyEntries(from: root, kind: kind)
                MediaCacheStorage.trim(directory: root, maxBytes: kind.maxBytes)
            }
        }
    }

    func localURL(
        for remoteURL: URL,
        kind: DownloadedMediaKind,
        suggestedFilename: String? = nil
    ) async throws -> URL {
        await startupMaintenance.value
        guard !remoteURL.isFileURL else { return remoteURL }
        let key = requestKey(for: remoteURL, kind: kind)
        if let cached = existingURL(
            for: remoteURL,
            kind: kind,
            suggestedFilename: suggestedFilename
        ) {
            MediaCacheStorage.touch(cached)
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        let destination = MediaFileCacheIO.destinationURL(
            for: remoteURL,
            kind: kind,
            suggestedFilename: suggestedFilename,
            fallbackExtension: "")
        let id = UUID()
        let task = Task.detached(priority: .utility) {
            try await MediaFileCacheIO.download(
                remoteURL: remoteURL,
                destination: destination,
                kind: kind)
        }
        inFlight[key] = (id, task)
        do {
            let result = try await task.value
            if inFlight[key]?.id == id { inFlight[key] = nil }
            return result
        } catch {
            if inFlight[key]?.id == id { inFlight[key] = nil }
            throw error
        }
    }

    /// 自己刚发送成功的语音/文件从 outbox 提升到缓存，避免 ACK 后立刻回源下载。
    func importLocalFile(
        _ sourceURL: URL,
        remoteURL: URL,
        kind: DownloadedMediaKind,
        suggestedFilename: String? = nil
    ) async {
        await startupMaintenance.value
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        let key = requestKey(for: remoteURL, kind: kind)
        if existingURL(
            for: remoteURL,
            kind: kind,
            suggestedFilename: suggestedFilename
        ) != nil { return }
        if let existing = inFlight[key] {
            _ = try? await existing.task.value
            return
        }
        let destination = MediaFileCacheIO.destinationURL(
            for: remoteURL,
            kind: kind,
            suggestedFilename: suggestedFilename,
            fallbackExtension: sourceURL.pathExtension)
        let id = UUID()
        let task = Task.detached(priority: .utility) {
            try MediaFileCacheIO.importFile(
                sourceURL: sourceURL,
                destination: destination,
                kind: kind)
        }
        inFlight[key] = (id, task)
        _ = try? await task.value
        if inFlight[key]?.id == id { inFlight[key] = nil }
    }

    func removeMedia(for remoteURL: URL) async {
        await startupMaintenance.value
        let digest = MediaCacheIdentity.digest(for: remoteURL)
        var cancelledTasks: [Task<URL, Error>] = []
        for kind in DownloadedMediaKind.allCases {
            let key = requestKey(for: remoteURL, kind: kind)
            if let task = inFlight.removeValue(forKey: key)?.task {
                task.cancel()
                cancelledTasks.append(task)
            }
        }
        for task in cancelledTasks {
            _ = try? await task.value
        }
        for kind in DownloadedMediaKind.allCases {
            let root = MediaFileCacheIO.rootDirectory(for: kind)
            switch kind {
            case .voice:
                let matches = (try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil
                ))?.filter { $0.lastPathComponent.hasPrefix("\(digest).") } ?? []
                for match in matches {
                    try? FileManager.default.removeItem(at: match)
                }
            case .file:
                try? FileManager.default.removeItem(
                    at: root.appendingPathComponent(digest, isDirectory: true))
            }
        }
    }

    func stats() async -> DownloadedMediaCacheStats {
        await startupMaintenance.value
        return await Task.detached(priority: .utility) {
            DownloadedMediaCacheStats(
                voice: MediaCacheStorage.stats(at: MediaFileCacheIO.rootDirectory(for: .voice)),
                files: MediaCacheStorage.stats(at: MediaFileCacheIO.rootDirectory(for: .file)))
        }.value
    }

    func clearAll() async {
        await startupMaintenance.value
        let tasks = inFlight.values.map { $0.task }
        inFlight.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = try? await task.value
        }
        await Task.detached(priority: .utility) {
            for kind in DownloadedMediaKind.allCases {
                MediaCacheStorage.removeContents(of: MediaFileCacheIO.rootDirectory(for: kind))
            }
        }.value
    }

    private func requestKey(for remoteURL: URL, kind: DownloadedMediaKind) -> String {
        "\(kind.rawValue)|\(MediaCacheIdentity.value(for: remoteURL))"
    }

    private func existingURL(
        for remoteURL: URL,
        kind: DownloadedMediaKind,
        suggestedFilename: String?
    ) -> URL? {
        let destination = MediaFileCacheIO.destinationURL(
            for: remoteURL,
            kind: kind,
            suggestedFilename: suggestedFilename,
            fallbackExtension: "")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { return destination }
        guard kind == .file else { return nil }
        let directory = destination.deletingLastPathComponent()
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.first(where: {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        })
    }

}
