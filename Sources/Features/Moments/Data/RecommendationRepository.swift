import Foundation

enum RecommendationRepositoryError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "推荐地址无效"
        case .invalidResponse: return "推荐服务返回了无法识别的数据"
        case .unauthorized: return "登录已失效，请重新登录"
        case .server(let code): return "推荐服务暂时不可用（\(code)）"
        }
    }
}

final class RecommendationRepository {
    static let changedNotification = Notification.Name("dailyRecommendationsChanged")

    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func today(token: String) async throws -> RecommendationTodaySnapshot {
        let data = try await request(path: "api/v2/recommendations/today", token: token)
        return try JSONDecoder().decode(RecommendationTodaySnapshot.self, from: data)
    }

    func refresh(token: String) async throws -> RecommendationItem {
        let data = try await request(
            path: "api/v2/recommendations/refresh", method: "POST", token: token)
        let item = try JSONDecoder().decode(ItemEnvelope.self, from: data).recommendation
        notifyChanged()
        return item
    }

    func send(_ content: String, token: String) async throws -> RecommendationItem {
        let data = try await request(
            path: "api/v2/recommendations",
            method: "POST",
            body: ContentBody(content: content),
            token: token)
        let item = try JSONDecoder().decode(ItemEnvelope.self, from: data).recommendation
        notifyChanged()
        return item
    }

    func unreadCount(token: String) async throws -> Int {
        let data = try await request(
            path: "api/v2/recommendations/unread-count", token: token)
        return try JSONDecoder().decode(UnreadEnvelope.self, from: data).unreadCount
    }

    func history(
        cursor: String? = nil,
        limit: Int = 30,
        token: String
    ) async throws -> RecommendationHistoryPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(
            path: "api/v2/recommendations/history", query: query, token: token)
        return try JSONDecoder().decode(RecommendationHistoryPage.self, from: data)
    }

    func markRead(_ recommendationId: String, token: String) async throws {
        _ = try await request(
            path: "api/v2/recommendations/\(recommendationId)/read",
            method: "POST",
            token: token)
        notifyChanged()
    }

    func deleteFromHistory(_ recommendationId: String, token: String) async throws {
        _ = try await request(
            path: "api/v2/recommendations/\(recommendationId)",
            method: "DELETE",
            token: token)
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        token: String
    ) async throws -> Data {
        try await request(path: path, query: query, method: method, bodyData: nil, token: token)
    }

    private func request<Body: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        body: Body,
        token: String
    ) async throws -> Data {
        try await request(
            path: path, query: query, method: method,
            bodyData: try JSONEncoder().encode(body), token: token)
    }

    private func request(
        path: String,
        query: [URLQueryItem],
        method: String,
        bodyData: Data?,
        token: String
    ) async throws -> Data {
        guard let base = URL(string: path, relativeTo: ServerConfig.baseURL),
              var components = URLComponents(
                url: base.absoluteURL, resolvingAgainstBaseURL: true) else {
            throw RecommendationRepositoryError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw RecommendationRepositoryError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if bodyData != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecommendationRepositoryError.invalidResponse
        }
        if http.statusCode == 401 { throw RecommendationRepositoryError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw RecommendationRepositoryError.server(http.statusCode)
        }
        return data
    }
}

private extension RecommendationRepository {
    struct ItemEnvelope: Decodable { let recommendation: RecommendationItem }
    struct UnreadEnvelope: Decodable { let unreadCount: Int }
    struct ContentBody: Encodable { let content: String }
}
