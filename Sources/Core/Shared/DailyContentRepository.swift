import Foundation

struct DailyContentRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(token: String) async -> DailyContent? {
        guard let request = authorizedRequest("api/daily", token: token),
              let (data, response) = try? await httpClient.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DailyContent.self, from: data)
    }

    func regenerateRecommendation(token: String) async -> Recommendation? {
        guard let request = authorizedRequest(
            "api/daily/recommend", method: "POST", token: token),
              let (data, response) = try? await httpClient.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Response: Decodable { let recommend: Recommendation? }
        return (try? JSONDecoder().decode(Response.self, from: data))?.recommend
    }

    private func authorizedRequest(
        _ path: String,
        method: String = "GET",
        token: String
    ) -> URLRequest? {
        guard let relative = URL(string: path, relativeTo: ServerConfig.baseURL) else { return nil }
        var request = URLRequest(url: relative.absoluteURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
