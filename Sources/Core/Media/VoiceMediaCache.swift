import Foundation

actor VoiceMediaCache {
    static let shared = VoiceMediaCache()

    private var inFlight: [URL: Task<URL, Error>] = [:]

    func localURL(for sourceURL: URL) async throws -> URL {
        guard !sourceURL.isFileURL else { return sourceURL }
        let destinationURL = cachedURL(for: sourceURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        if let task = inFlight[sourceURL] {
            return try await task.value
        }

        let task = Task<URL, Error> {
            let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let directoryURL = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL
        }
        inFlight[sourceURL] = task
        defer { inFlight[sourceURL] = nil }
        return try await task.value
    }

    private func cachedURL(for sourceURL: URL) -> URL {
        let encoded = Data(sourceURL.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let name = String(encoded.prefix(120))
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceMedia", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension)
    }
}
