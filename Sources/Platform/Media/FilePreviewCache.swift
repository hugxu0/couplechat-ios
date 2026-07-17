import Foundation

enum FilePreviewCache {
    static func localURL(
        for remoteURL: URL,
        messageID: String,
        displayName: String
    ) async throws -> URL {
        let fileManager = FileManager.default
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let directory = caches
            .appendingPathComponent("FilePreviews", isDirectory: true)
            .appendingPathComponent(safeComponent(messageID, fallback: UUID().uuidString), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let preferredName = safeComponent(displayName, fallback: remoteURL.lastPathComponent)
        let destination = directory.appendingPathComponent(
            preferredName.isEmpty ? "文件" : preferredName,
            isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) { return destination }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 45
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch where fileManager.fileExists(atPath: destination.path) {
            // 两个入口同时预览同一文件时，先完成的一方已经提供了完整缓存。
        }
        return destination
    }

    private static func safeComponent(_ value: String, fallback: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = candidate.isEmpty ? fallback : candidate
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = source
            .components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return String(cleaned.prefix(120))
    }
}
