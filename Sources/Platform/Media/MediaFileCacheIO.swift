import Foundation

enum MediaFileCacheIO {
    private static let maximumFileBytes: Int64 = 50 * 1_024 * 1_024
    private static let downloadGate = MediaDownloadGate(limit: 2)

    static func destinationURL(
        for remoteURL: URL,
        kind: DownloadedMediaKind,
        suggestedFilename: String?,
        fallbackExtension: String
    ) -> URL {
        let digest = MediaCacheIdentity.digest(for: remoteURL)
        let root = rootDirectory(for: kind)
        switch kind {
        case .voice:
            let ext = preferredExtension(
                suggestedFilename: suggestedFilename,
                remoteURL: remoteURL,
                fallback: fallbackExtension.isEmpty ? "m4a" : fallbackExtension)
            return root.appendingPathComponent(digest).appendingPathExtension(ext)
        case .file:
            let directory = root.appendingPathComponent(digest, isDirectory: true)
            let safeName = safeFilename(
                suggestedFilename,
                remoteURL: remoteURL,
                fallbackExtension: fallbackExtension)
            return directory.appendingPathComponent(safeName)
        }
    }

    static func rootDirectory(for kind: DownloadedMediaKind) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(kind.directoryName, isDirectory: true)
    }

    /// 旧版语音 key 含 sig/exp，文件预览以 messageId 建目录；无法可靠迁移。
    static func removeLegacyEntries(from root: URL, kind: DownloadedMediaKind) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            let identity = kind == .voice
                ? item.deletingPathExtension().lastPathComponent
                : item.lastPathComponent
            let isStableDigest = identity.count == 64 && identity.allSatisfy {
                $0.isNumber || "abcdef".contains($0)
            }
            if !isStableDigest {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    static func download(
        remoteURL: URL,
        destination: URL,
        kind: DownloadedMediaKind
    ) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = kind == .voice ? 30 : 60
        let (temporaryURL, response) = try await downloadFile(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw MediaFileCacheError.invalidResponse
        }
        if response.expectedContentLength > maximumFileBytes {
            throw MediaFileCacheError.fileTooLarge
        }
        guard let size = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0 else {
            throw MediaFileCacheError.emptyFile
        }
        guard Int64(size) <= maximumFileBytes else {
            throw MediaFileCacheError.fileTooLarge
        }
        return try publish(
            temporaryURL: temporaryURL,
            destination: destination,
            kind: kind)
    }

    static func importFile(
        sourceURL: URL,
        destination: URL,
        kind: DownloadedMediaKind
    ) throws -> URL {
        guard let size = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0 else {
            throw MediaFileCacheError.emptyFile
        }
        guard Int64(size) <= maximumFileBytes else {
            throw MediaFileCacheError.fileTooLarge
        }
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).importing")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: sourceURL, to: temporary)
        try Task.checkCancellation()
        return try publish(
            temporaryURL: temporary,
            destination: destination,
            kind: kind)
    }

    private static func publish(
        temporaryURL: URL,
        destination: URL,
        kind: DownloadedMediaKind
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        MediaCacheStorage.markDirectoryAsLocalCache(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            MediaCacheStorage.touch(destination)
            return destination
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch where fileManager.fileExists(atPath: destination.path) {
            MediaCacheStorage.touch(destination)
            return destination
        }
        MediaCacheStorage.protect(destination)
        MediaCacheStorage.touch(destination)
        MediaCacheStorage.trim(
            directory: rootDirectory(for: kind),
            maxBytes: kind.maxBytes,
            preserving: [destination])
        return destination
    }

    private static func downloadFile(
        for request: URLRequest
    ) async throws -> (URL, URLResponse) {
        await downloadGate.acquire()
        do {
            let result = try await URLSession.shared.download(for: request)
            await downloadGate.release()
            return result
        } catch {
            await downloadGate.release()
            throw error
        }
    }

    private static func safeFilename(
        _ suggestedFilename: String?,
        remoteURL: URL,
        fallbackExtension: String
    ) -> String {
        let suggested = suggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? remoteURL.lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var cleaned = source
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        if cleaned.isEmpty || cleaned.hasPrefix("up_") {
            cleaned = "文件"
        }
        cleaned = String(cleaned.prefix(120))
        if URL(fileURLWithPath: cleaned).pathExtension.isEmpty {
            let ext = preferredExtension(
                suggestedFilename: suggestedFilename,
                remoteURL: remoteURL,
                fallback: fallbackExtension.isEmpty ? "bin" : fallbackExtension)
            cleaned += ".\(ext)"
        }
        return cleaned
    }

    private static func preferredExtension(
        suggestedFilename: String?,
        remoteURL: URL,
        fallback: String
    ) -> String {
        let suggestedExtension = suggestedFilename.map {
            URL(fileURLWithPath: $0).pathExtension
        } ?? ""
        let value = !suggestedExtension.isEmpty
            ? suggestedExtension
            : (!remoteURL.pathExtension.isEmpty ? remoteURL.pathExtension : fallback)
        let safe = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? "bin" : String(safe.prefix(12))
    }
}
