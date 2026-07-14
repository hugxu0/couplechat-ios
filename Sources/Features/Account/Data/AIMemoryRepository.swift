import Foundation

struct AIMemoryRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(
        scope: AIMemoryScopeFilter,
        layer: AIMemoryLayer?,
        query: String,
        subject: String? = nil,
        status: AIMemoryStatusFilter = .active,
        token: String,
        cursor: String? = nil
    ) async throws -> AIMemorySnapshot {
        var queryItems = [URLQueryItem(name: "scope", value: scope.rawValue)]
        if let layer { queryItems.append(URLQueryItem(name: "layer", value: layer.rawValue)) }
        if let subject { queryItems.append(URLQueryItem(name: "subject", value: subject)) }
        queryItems.append(URLQueryItem(name: "status", value: status.rawValue))
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty { queryItems.append(URLQueryItem(name: "q", value: search)) }
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        let request = try authorizedRequest(path: "api/me/memory", token: token, query: queryItems)
        let response: ListResponse = try await perform(request)
        return AIMemorySnapshot(
            items: response.items,
            stats: response.stats,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore ?? false)
    }

    func sources(for memoryId: String, token: String) async throws -> [AIMemorySource] {
        let request = try authorizedRequest(
            path: "api/me/memory/\(memoryId)/sources", token: token)
        let response: SourcesResponse = try await perform(request)
        return response.sources
    }

    func update(
        _ memoryId: String,
        content: String,
        importance: Int,
        baseVersion: Int,
        token: String
    ) async throws -> AIMemoryItem {
        var request = try authorizedRequest(
            path: "api/me/memory/\(memoryId)", method: "PATCH", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "content": content,
            "importance": importance,
            "baseVersion": baseVersion,
        ])
        let response: ItemResponse = try await perform(request)
        return response.item
    }

    func delete(_ memoryId: String, token: String) async throws {
        let request = try authorizedRequest(
            path: "api/me/memory/\(memoryId)", method: "DELETE", token: token)
        let _: SuccessResponse = try await perform(request)
    }

    func refresh(_ scope: AIMemoryScopeFilter, token: String) async throws -> AIMemoryStats {
        guard scope != .all else { throw AIMemoryRepositoryError.invalidRequest }
        var request = try authorizedRequest(
            path: "api/me/memory/refresh", method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["scope": scope.rawValue])
        let response: RefreshResponse = try await perform(request)
        return response.stats
    }

    private func authorizedRequest(
        path: String,
        method: String = "GET",
        token: String,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard let relative = URL(string: path, relativeTo: ServerConfig.baseURL),
              var components = URLComponents(url: relative.absoluteURL, resolvingAgainstBaseURL: false) else {
            throw AIMemoryRepositoryError.invalidRequest
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AIMemoryRepositoryError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIMemoryRepositoryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw AIMemoryRepositoryError.unauthorized }
            if http.statusCode == 409,
               let current = try? JSONDecoder().decode(ItemResponse.self, from: data) {
                throw AIMemoryRepositoryError.conflict(current.item)
            }
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw AIMemoryRepositoryError.server(code ?? "request_failed")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AIMemoryRepositoryError.invalidResponse
        }
    }

    private struct ListResponse: Decodable {
        let items: [AIMemoryItem]
        let stats: AIMemoryStats
        let nextCursor: String?
        let hasMore: Bool?
    }
    private struct SourcesResponse: Decodable { let sources: [AIMemorySource] }
    private struct ItemResponse: Decodable { let item: AIMemoryItem }
    private struct SuccessResponse: Decodable { let ok: Bool }
    private struct RefreshResponse: Decodable { let stats: AIMemoryStats }
}

enum AIMemoryRepositoryError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case unauthorized
    case server(String)
    case conflict(AIMemoryItem)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "请求参数无效"
        case .invalidResponse: return "服务器返回了无法识别的数据"
        case .unauthorized: return "登录已失效，请重新登录"
        case let .server(code): return ServerErrorCode.message(for: code, fallback: "Memory 操作失败")
        case .conflict: return "这条记忆已在另一台设备更新，已载入最新版本"
        }
    }
}
