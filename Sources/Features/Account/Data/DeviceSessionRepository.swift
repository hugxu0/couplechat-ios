import Foundation

struct AccountDevice: Decodable, Identifiable, Equatable {
    let id: String
    let installationId: String
    let platform: String
    let deviceName: String
    let appVersion: String
    let buildNumber: String
    let protocolVersion: Int
    let barkEnabled: Bool
    let lastSeenAt: Double
}

private struct DeviceListEnvelope: Decodable {
    let devices: [AccountDevice]
}

final class DeviceSessionRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func list(token: String) async throws -> [AccountDevice] {
        guard let request = APIRequestFactory.authorized(
            path: "api/v2/me/devices", token: token) else {
            throw DeviceSessionError.message("服务器地址无效")
        }
        let data = try await responseData(for: request, expectedStatus: 200)
        return try JSONDecoder().decode(DeviceListEnvelope.self, from: data).devices
    }

    func revoke(id: String, token: String) async throws {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DeviceSessionError.message("设备标识无效")
        }
        guard let request = APIRequestFactory.authorized(
            path: "api/v2/me/devices/\(encoded)", method: "DELETE", token: token) else {
            throw DeviceSessionError.message("服务器地址无效")
        }
        _ = try await responseData(for: request, expectedStatus: 200)
    }

    private func responseData(for request: URLRequest, expectedStatus: Int) async throws -> Data {
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeviceSessionError.message("服务器响应无效")
        }
        guard http.statusCode == expectedStatus else {
            let code = APIRequestFactory.errorCode(from: data)
            throw DeviceSessionError.message(
                ServerErrorCode.message(for: code, fallback: "设备操作失败，请稍后重试"))
        }
        return data
    }
}

private enum DeviceSessionError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}
