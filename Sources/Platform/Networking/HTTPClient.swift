import Foundation

/// 可替换的网络边界。生产环境使用 URLSession，测试可注入固定响应的 client。
protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
}

extension HTTPClient {
    /// 测试替身和简单实现可复用 data(for:)；生产 URLSession 实现会覆盖为真正的文件上传。
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        var request = request
        request.httpBody = try Data(contentsOf: fileURL)
        return try await data(for: request)
    }
}

struct URLSessionHTTPClient: HTTPClient {
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        // URLSession.shared 的资源超时很长，上传链路断在半途时会长期占住 outbox。
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.defaultSession
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, fromFile: fileURL)
    }
}
