import Foundation

struct PersonalItemsRepository {
    static let changedNotification = Notification.Name("personalItemChanged")

    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(
        kind: PersonalItemKind? = nil,
        scope: String = "personal",
        token: String
    ) async -> [PersonalItem] {
        var query: [String] = []
        if let kind { query.append("kind=\(kind.rawValue)") }
        query.append("scope=\(scope)")
        guard let request = APIRequestFactory.authorized(
            path: "api/me/items?\(query.joined(separator: "&"))", token: token),
              let (data, response) = try? await httpClient.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(ItemsResponse.self, from: data))?.items ?? []
    }

    func create(
        kind: PersonalItemKind,
        scope: String = "personal",
        title: String,
        bodyMarkdown: String,
        dueAt: Int?,
        token: String
    ) async -> PersonalItem? {
        var body: [String: Any] = [
            "kind": kind.rawValue,
            "scope": scope,
            "title": title,
            "bodyMarkdown": bodyMarkdown,
        ]
        if let dueAt { body["dueAt"] = dueAt }
        return await send(path: "api/me/items", method: "POST", body: body, token: token)
    }

    func update(
        _ item: PersonalItem,
        title: String? = nil,
        bodyMarkdown: String? = nil,
        dueAt: Int? = nil,
        clearsDueAt: Bool = false,
        isDone: Bool? = nil,
        token: String
    ) async -> PersonalItem? {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let bodyMarkdown { body["bodyMarkdown"] = bodyMarkdown }
        if clearsDueAt { body["dueAt"] = NSNull() } else if let dueAt { body["dueAt"] = dueAt }
        if let isDone { body["isDone"] = isDone }
        return await send(
            path: "api/me/items/\(item.id)", method: "PATCH", body: body, token: token)
    }

    func delete(_ item: PersonalItem, token: String) async -> Bool {
        guard let request = APIRequestFactory.authorized(
            path: "api/me/items/\(item.id)", method: "DELETE", token: token),
              let (_, response) = try? await httpClient.data(for: request) else { return false }
        let succeeded = (response as? HTTPURLResponse)?.statusCode == 200
        if succeeded { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
        return succeeded
    }

    private func send(
        path: String,
        method: String,
        body: [String: Any],
        token: String
    ) async -> PersonalItem? {
        guard var request = APIRequestFactory.authorized(
            path: path, method: method, token: token) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await httpClient.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code),
              let item = (try? JSONDecoder().decode(ItemResponse.self, from: data))?.item else { return nil }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        return item
    }

    private struct ItemsResponse: Decodable { let items: [PersonalItem] }
    private struct ItemResponse: Decodable { let item: PersonalItem }
}
