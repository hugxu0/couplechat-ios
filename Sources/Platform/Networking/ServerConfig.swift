import Foundation

enum ServerConfig {
    static var baseURL: URL {
        if let urlString = Bundle.main.object(forInfoDictionaryKey: "SERVER_BASE_URL") as? String,
           let url = URL(string: urlString) {
            return url
        }
        return URL(string: "https://hoo66.top")!
    }

    /// Debug 构建是否指向生产入口（IOS-003 风险提示）。
    static var isProductionEndpoint: Bool {
        let host = baseURL.host?.lowercased() ?? ""
        return host == "hoo66.top" || host.hasSuffix(".hoo66.top")
    }

#if DEBUG
    /// Debug 默认禁止「开发开关类」批量写生产；用户可在设置临时打开。
    static var allowDebugProductionWrites: Bool {
        get { UserDefaults.standard.bool(forKey: "debug.allow_production_writes") }
        set { UserDefaults.standard.set(newValue, forKey: "debug.allow_production_writes") }
    }

    static var shouldWarnProductionInDebug: Bool {
        isProductionEndpoint
    }
#endif

    static func resolveMediaURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
            return URL(string: raw)
        }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}
