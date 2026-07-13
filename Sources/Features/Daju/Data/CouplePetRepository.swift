import Foundation

struct CouplePetRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(token: String) async throws -> CouplePetSnapshot {
        let request = try authorizedRequest(path: "api/v2/pet", token: token)
        return try await perform(request)
    }

    func interact(
        kind: PetInteractionKind,
        baseVersion: Int,
        token: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> CouplePetSnapshot {
        try await mutate(
            path: "api/v2/pet/interactions",
            method: "POST",
            body: InteractionBody(
                kind: kind.rawValue,
                idempotencyKey: idempotencyKey,
                baseVersion: baseVersion),
            token: token)
    }

    private func mutate<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        token: String
    ) async throws -> CouplePetSnapshot {
        var request = try authorizedRequest(path: path, method: method, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func authorizedRequest(
        path: String,
        method: String = "GET",
        token: String
    ) throws -> URLRequest {
        guard let relative = URL(string: path, relativeTo: ServerConfig.baseURL) else {
            throw CouplePetRepositoryError.invalidRequest
        }
        var request = URLRequest(url: relative.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CouplePetRepositoryError.invalidResponse
        }
        if http.statusCode == 401 { throw CouplePetRepositoryError.unauthorized }
        let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
        if http.statusCode == 409 {
            if code == "version_conflict" {
                throw CouplePetRepositoryError.conflict
            }
            throw CouplePetRepositoryError.server(code ?? "request_conflict")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CouplePetRepositoryError.server(code ?? "request_failed")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CouplePetRepositoryError.invalidResponse
        }
    }

    private struct InteractionBody: Encodable {
        let kind: String
        let idempotencyKey: String
        let baseVersion: Int
    }

    private struct ErrorResponse: Decodable { let error: String }
}

enum CouplePetRepositoryError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case unauthorized
    case conflict
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "大橘请求参数无效"
        case .invalidResponse: return "大橘的数据暂时无法识别"
        case .unauthorized: return "登录已失效，请重新登录"
        case .conflict: return "另一台设备刚刚更新了小窝，已为你刷新"
        case let .server(code):
            return ServerErrorCode.message(for: code, fallback: "大橘暂时没有回应")
        }
    }
}
