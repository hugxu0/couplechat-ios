import Foundation

struct DailyContentRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(token: String) async -> DailyContent? {
        guard let request = APIRequestFactory.authorized(path: "api/daily", token: token),
              let (data, response) = try? await httpClient.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DailyContent.self, from: data)
    }
}
