import Foundation

struct DajuDiary: Identifiable, Decodable, Equatable {
    let id: String
    let coupleId: String
    let dayKey: String
    let title: String
    let body: String
    let source: String
    let createdAt: Double
    let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title, body, source
        case coupleId
        case dayKey
        case createdAt
        case updatedAt
    }
}

@MainActor
final class DajuDiaryRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func list(token: String, limit: Int = 30) async throws -> [DajuDiary] {
        var components = URLComponents(
            url: ServerConfig.baseURL.appendingPathComponent("api/v2/ai/diaries"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(DiaryListResponse.self, from: data)
        return decoded.list
    }

    func ensureYesterday(token: String) async throws -> DajuDiary? {
        var request = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/v2/ai/diaries/ensure"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(DiaryOneResponse.self, from: data).diary
    }
}

private struct DiaryListResponse: Decodable {
    let ok: Bool
    let list: [DajuDiary]
}

private struct DiaryOneResponse: Decodable {
    let ok: Bool
    let diary: DajuDiary
}
