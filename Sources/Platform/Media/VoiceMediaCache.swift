import Foundation

actor VoiceMediaCache {
    static let shared = VoiceMediaCache()

    func localURL(for sourceURL: URL) async throws -> URL {
        try await MediaFileCache.shared.localURL(for: sourceURL, kind: .voice)
    }
}
