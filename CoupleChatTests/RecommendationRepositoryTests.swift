import Foundation
import XCTest
@testable import CoupleChat

private actor RecommendationHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int
    private(set) var request: URLRequest?

    init(_ json: String, statusCode: Int = 200) {
        data = Data(json.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (
            data,
            HTTPURLResponse(
                url: request.url!, statusCode: statusCode,
                httpVersion: nil, headerFields: nil)!)
    }
}

final class RecommendationRepositoryTests: XCTestCase {
    func testTodayDecodesSharedDajuAndLatestUnreadRecommendation() async throws {
        let client = RecommendationHTTPClient(#"""
        {"cycleDate":"2026-07-15","daju":{"id":"r1","sourceKind":"daju",
        "sourceName":"大橘","content":"今晚一起散散步吧。","cycleDate":"2026-07-15",
        "generationKind":"daily","createdAt":1000,"isRead":true,"isMine":false},
        "partner":{"id":"r2","sourceKind":"member","sourceUsername":"si","sourceName":"小偲",
        "recipientUsername":"xu","content":"回家买草莓。","cycleDate":"2026-07-15",
        "generationKind":"manual","createdAt":2000,"isRead":false,"isMine":false},
        "latestUnread":{"id":"r2","sourceKind":"member","sourceUsername":"si","sourceName":"小偲",
        "recipientUsername":"xu","content":"回家买草莓。","cycleDate":"2026-07-15",
        "generationKind":"manual","createdAt":2000,"isRead":false,"isMine":false},"unreadCount":2}
        """#)

        let snapshot = try await RecommendationRepository(httpClient: client).today(token: "token")

        XCTAssertEqual(snapshot.daju.content, "今晚一起散散步吧。")
        XCTAssertEqual(snapshot.partner?.sourceName, "小偲")
        XCTAssertEqual(snapshot.latestUnread?.id, "r2")
        XCTAssertEqual(snapshot.unreadCount, 2)
        let request = await client.request
        XCTAssertEqual(request?.url?.path, "/api/v2/recommendations/today")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testSendRecommendationUsesOnlyContentField() async throws {
        let client = RecommendationHTTPClient(#"""
        {"recommendation":{"id":"r3","sourceKind":"member","sourceUsername":"xu",
        "sourceName":"小旭","recipientUsername":"si","content":"一起看电影。",
        "cycleDate":"2026-07-15","generationKind":"manual","createdAt":3000,
        "isRead":true,"isMine":true}}
        """#)

        _ = try await RecommendationRepository(httpClient: client).send("一起看电影。", token: "token")

        let request = await client.request
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.url?.path, "/api/v2/recommendations")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["content"] as? String, "一起看电影。")
        XCTAssertEqual(body?.count, 1)
    }

    func testDeleteHistoryUsesAccountScopedDeleteEndpoint() async throws {
        let client = RecommendationHTTPClient(#"{"ok":true}"#)

        try await RecommendationRepository(httpClient: client)
            .deleteFromHistory("r4", token: "token")

        let request = await client.request
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertEqual(request?.url?.path, "/api/v2/recommendations/r4")
    }
}
