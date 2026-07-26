import Foundation

/// 可替换的网络边界。生产环境使用 URLSession，测试可注入固定响应的 client。
protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse)
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse)
}

extension HTTPClient {
    /// 测试替身和简单实现可复用 data(for:)；生产 URLSession 实现会覆盖为真正的文件上传。
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        var request = request
        request.httpBody = try Data(contentsOf: fileURL)
        return try await data(for: request)
    }

    /// 默认忽略进度；只有生产 URLSession 实现真正上报。
    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse) {
        try await upload(for: request, fromFile: fileURL)
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

    func upload(
        for request: URLRequest,
        fromFile fileURL: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse) {
        guard let onProgress else { return try await session.upload(for: request, fromFile: fileURL) }
        // async 版 URLSession API 不暴露 task，进度只能走完成回调 + KVO。
        // 完成回调恰好触发一次，continuation 不会二次 resume；取消时 cancel task，
        // 完成回调会带 cancelled 错误收尾。
        final class TaskBox: @unchecked Sendable {
            var task: URLSessionUploadTask?
            var observation: NSKeyValueObservation?
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.task = task
                box.observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                    onProgress(progress.fractionCompleted)
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}
