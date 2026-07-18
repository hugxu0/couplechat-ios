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

    /// 新签名媒体使用同一份 sig/exp 读取上传时生成的静态缩略图。
    /// 历史 `/uploads/`、本地 file URL 和未知媒体地址没有缩略图，调用方回退原图。
    static func mediaThumbnailURL(for originalURL: URL?) -> URL? {
        guard let originalURL,
              var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https",
              components.host?.lowercased() == baseURL.host?.lowercased() else { return nil }
        let pathParts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathParts.count == 2,
              pathParts[0] == "media",
              pathParts[1].hasPrefix("up_") else { return nil }
        components.path += "/thumbnail"
        return components.url
    }
}
