import Foundation

struct CalendarRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func events(monthContaining date: Date, token: String) async throws -> [CalendarEvent] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        let query = [
            URLQueryItem(name: "view", value: "month"),
            URLQueryItem(name: "month", value: formatter.string(from: date)),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
            URLQueryItem(name: "limit", value: "500"),
        ]
        let data = try await request(path: "api/v2/calendar/events", query: query, token: token)
        return try JSONDecoder().decode(EventsEnvelope.self, from: data).events
    }

    func create(
        title: String,
        notes: String,
        startAt: Int,
        endAt: Int?,
        isAllDay: Bool,
        scope: String,
        token: String
    ) async throws -> CalendarEvent {
        let range = normalizedRange(startAt: startAt, endAt: endAt, isAllDay: isAllDay)
        let body = CreateMutation(
            scope: serverScope(scope), title: title, notes: notes,
            startAt: range.startAt, endAt: range.endAt,
            timezone: TimeZone.current.identifier, allDay: isAllDay)
        return try await mutate(path: "api/v2/calendar/events", method: "POST", body: body, token: token)
    }

    func update(
        _ event: CalendarEvent,
        title: String,
        notes: String,
        startAt: Int,
        endAt: Int?,
        isAllDay: Bool,
        token: String
    ) async throws -> CalendarEvent {
        let range = normalizedRange(startAt: startAt, endAt: endAt, isAllDay: isAllDay)
        let body = UpdateMutation(
            title: title, notes: notes, startAt: range.startAt, endAt: range.endAt,
            timezone: TimeZone.current.identifier, allDay: isAllDay, baseVersion: event.version)
        return try await mutate(
            path: "api/v2/calendar/events/\(event.id)", method: "PATCH", body: body, token: token)
    }

    func setCompleted(_ event: CalendarEvent, completed: Bool, token: String) async throws -> CalendarEvent {
        let body = CompleteMutation(completed: completed, baseVersion: event.version)
        return try await mutate(
            path: "api/v2/calendar/events/\(event.id)/complete",
            method: "POST", body: body, token: token)
    }

    func delete(_ event: CalendarEvent, token: String) async throws {
        _ = try await request(
            path: "api/v2/calendar/events/\(event.id)",
            method: "DELETE",
            body: VersionMutation(baseVersion: event.version),
            token: token)
    }

    private func mutate<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        token: String
    ) async throws -> CalendarEvent {
        let data = try await request(path: path, method: method, body: body, token: token)
        return try JSONDecoder().decode(EventEnvelope.self, from: data).event
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        token: String
    ) async throws -> Data {
        try await requestData(path: path, query: query, method: method, body: nil, token: token)
    }

    private func request<Body: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        body: Body,
        token: String
    ) async throws -> Data {
        try await requestData(
            path: path, query: query, method: method,
            body: try JSONEncoder().encode(body), token: token)
    }

    private func requestData(
        path: String,
        query: [URLQueryItem],
        method: String,
        body: Data?,
        token: String
    ) async throws -> Data {
        guard let base = URL(string: path, relativeTo: ServerConfig.baseURL),
              var components = URLComponents(url: base.absoluteURL, resolvingAgainstBaseURL: true) else {
            throw V2RepositoryError.invalidRequest
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw V2RepositoryError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await httpClient.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw V2RepositoryError.invalidResponse
        }
        if code == 409,
           let conflict = try? JSONDecoder().decode(EventEnvelope.self, from: data) {
            throw V2RepositoryError.calendarConflict(conflict.event)
        }
        guard (200..<300).contains(code) else { throw V2RepositoryError.server(code) }
        return data
    }

    private func serverScope(_ scope: String) -> String {
        scope == "personal" ? "private" : scope
    }

    private func normalizedRange(
        startAt: Int,
        endAt: Int?,
        isAllDay: Bool
    ) -> (startAt: Int, endAt: Int) {
        guard isAllDay else { return (startAt, endAt ?? startAt + 3_600_000) }
        let calendar = Calendar.autoupdatingCurrent
        let rawStart = Date(timeIntervalSince1970: Double(startAt) / 1_000)
        let start = calendar.startOfDay(for: rawStart)
        let selectedEnd = endAt.map {
            calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0) / 1_000))
        }
        let end = selectedEnd.flatMap { $0 > start ? $0 : nil }
            ?? calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return (
            Int(start.timeIntervalSince1970 * 1_000),
            Int(end.timeIntervalSince1970 * 1_000))
    }
}

private extension CalendarRepository {
    struct EventsEnvelope: Decodable { let events: [CalendarEvent] }
    struct EventEnvelope: Decodable { let event: CalendarEvent }
    struct CreateMutation: Encodable {
        let scope: String
        let title: String
        let notes: String
        let startAt: Int
        let endAt: Int
        let timezone: String
        let allDay: Bool
    }
    struct UpdateMutation: Encodable {
        let title: String
        let notes: String
        let startAt: Int
        let endAt: Int
        let timezone: String
        let allDay: Bool
        let baseVersion: Int
    }
    struct CompleteMutation: Encodable { let completed: Bool; let baseVersion: Int }
    struct VersionMutation: Encodable { let baseVersion: Int }
}
