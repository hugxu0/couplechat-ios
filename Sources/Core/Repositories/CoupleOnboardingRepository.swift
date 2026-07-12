import Foundation

struct CoupleInvite: Decodable, Equatable {
    let code: String
    let expiresAt: Double
}

struct CoupleCreationResult: Decodable {
    let coupleId: String
    let memberId: String
    let invite: CoupleInvite
}

private struct CoupleJoinResult: Decodable {
    let coupleId: String
    let memberId: String
}

private struct CoupleStatus: Decodable {
    let paired: Bool
}

final class CoupleOnboardingRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func status(token: String) async throws -> Bool {
        let request = authorizedRequest(path: "api/v2/me/couple", token: token)
        let data = try await responseData(for: request, expectedStatus: 200)
        return try JSONDecoder().decode(CoupleStatus.self, from: data).paired
    }

    func create(name: String, token: String) async throws -> CoupleCreationResult {
        var request = authorizedRequest(path: "api/v2/couples", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        let data = try await responseData(for: request, expectedStatus: 201)
        return try JSONDecoder().decode(CoupleCreationResult.self, from: data)
    }

    func join(code: String, token: String) async throws {
        var request = authorizedRequest(path: "api/v2/couples/join", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])
        let data = try await responseData(for: request, expectedStatus: 200)
        _ = try JSONDecoder().decode(CoupleJoinResult.self, from: data)
    }

    func newInvite(token: String) async throws -> CoupleInvite {
        var request = authorizedRequest(path: "api/v2/couples/invites", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await responseData(for: request, expectedStatus: 200)
        return try JSONDecoder().decode(InviteEnvelope.self, from: data).invite
    }

    private func authorizedRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: ServerConfig.baseURL.appendingPathComponent(path))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func responseData(for request: URLRequest, expectedStatus: Int) async throws -> Data {
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoupleOnboardingError.message("服务器响应无效")
        }
        guard http.statusCode == expectedStatus else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw CoupleOnboardingError.message(
                ServerErrorCode.message(for: code, fallback: "操作失败，请稍后重试"))
        }
        return data
    }
}

private struct InviteEnvelope: Decodable {
    let invite: CoupleInvite
}

private enum CoupleOnboardingError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}
