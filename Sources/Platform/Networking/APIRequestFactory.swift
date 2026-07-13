import Foundation

enum APIRequestFactory {
    static func authorized(
        path: String,
        method: String = "GET",
        token: String,
        timeout: TimeInterval = 15
    ) -> URLRequest? {
        guard let url = URL(string: path, relativeTo: ServerConfig.baseURL)?.absoluteURL else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func errorCode(from data: Data) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
    }
}
