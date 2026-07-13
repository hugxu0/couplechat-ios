import Foundation

final class SyncV2Repository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(after cursor: Int64, token: String) async throws -> SyncV2Page {
        var components = URLComponents(
            url: ServerConfig.baseURL.appendingPathComponent("api/v2/sync"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: "200"),
        ]
        guard let url = components?.url else { throw SyncV2Error.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncV2Error.invalidResponse }
        if http.statusCode == 401 { throw SyncV2Error.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw SyncV2Error.server(http.statusCode) }
        return try JSONDecoder().decode(SyncV2Page.self, from: data)
    }

    func acknowledge(_ cursor: Int64, token: String) async {
        var request = URLRequest(
            url: ServerConfig.baseURL.appendingPathComponent("api/v2/sync/ack"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["cursor": cursor])
        _ = try? await httpClient.data(for: request)
    }
}

enum SyncV2Error: Error {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)
}
