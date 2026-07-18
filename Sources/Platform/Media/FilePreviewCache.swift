import Foundation

enum FilePreviewCache {
    static func localURL(
        for remoteURL: URL,
        messageID _: String,
        displayName: String
    ) async throws -> URL {
        return try await MediaFileCache.shared.localURL(
            for: remoteURL,
            kind: .file,
            suggestedFilename: displayName)
    }
}
