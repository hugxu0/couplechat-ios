import Foundation

enum ServerConfig {
    static var baseURL: URL {
        if let urlString = Bundle.main.object(forInfoDictionaryKey: "SERVER_BASE_URL") as? String,
           let url = URL(string: urlString) {
            return url
        }
        return URL(string: "https://hoo66.top")!
    }

    static func resolveMediaURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}
