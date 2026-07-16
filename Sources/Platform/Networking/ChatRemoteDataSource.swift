import Foundation

struct ChatHistoryPage {
    let messages: [ChatMessage]
    let total: Int?
    let error: String?
}

struct ChatRemoteDataSource {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    func fetchMessages(
        _ request: MessagePageRequest,
        session: Session,
        context: String
    ) async -> [ChatMessage] {
        guard let url = messageURL(for: request) else { return [] }
        var urlRequest = authorizedRequest(url: url, session: session, timeout: 15)
        urlRequest.httpMethod = "GET"
        guard let (data, response) = try? await httpClient.data(for: urlRequest),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["list"] as? [[String: Any]] else { return [] }
        return Self.parseStrictMessages(
            rows,
            expectedChannel: request.channel,
            context: context) ?? []
    }

    func fetchHistoryPage(
        channel: ChatChannel,
        before: Double?,
        limit: Int,
        session: Session
    ) async -> ChatHistoryPage {
        let request = MessagePageRequest(channel: channel, before: before, limit: limit)
        guard let url = messageURL(for: request) else {
            return ChatHistoryPage(messages: [], total: nil, error: "同步地址无效")
        }
        let urlRequest = authorizedRequest(url: url, session: session, timeout: 20)
        do {
            let (data, response) = try await httpClient.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["list"] as? [[String: Any]] else {
                return ChatHistoryPage(messages: [], total: nil, error: "服务器同步响应无效")
            }
            let total = (root["total"] as? NSNumber)?.intValue ?? root["total"] as? Int
            guard let messages = Self.parseStrictMessages(
                rows,
                expectedChannel: channel.rawValue,
                context: "syncAllREST:\(channel.rawValue)")
            else {
                return ChatHistoryPage(
                    messages: [],
                    total: total,
                    error: "服务器历史消息包含无效格式或错误频道")
            }
            return ChatHistoryPage(
                messages: messages,
                total: total,
                error: nil)
        } catch {
            return ChatHistoryPage(messages: [], total: nil, error: error.localizedDescription)
        }
    }

    private static func parseStrictMessages(
        _ rows: [[String: Any]],
        expectedChannel: String,
        context: String
    ) -> [ChatMessage]? {
        var messages: [ChatMessage] = []
        messages.reserveCapacity(rows.count)
        for row in rows {
            guard let message = ChatMessageMapper.parse(row, context: context),
                  message.channel == expectedChannel else {
                return nil
            }
            messages.append(message)
        }
        return messages
    }

    private func messageURL(for request: MessagePageRequest) -> URL? {
        var components = URLComponents(
            url: ServerConfig.baseURL.appendingPathComponent("api/messages"),
            resolvingAgainstBaseURL: false)
        var query = [
            URLQueryItem(name: "channel", value: request.channel),
            URLQueryItem(name: "limit", value: String(request.limit)),
        ]
        let optionalItems: [(String, Double?)] = [
            ("since", request.since),
            ("after", request.after),
            ("before", request.before),
            ("around", request.around),
        ]
        for (name, value) in optionalItems {
            if let value {
                query.append(URLQueryItem(name: name, value: String(value)))
            }
        }
        components?.queryItems = query
        return components?.url
    }

    private func authorizedRequest(
        url: URL,
        session: Session,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
