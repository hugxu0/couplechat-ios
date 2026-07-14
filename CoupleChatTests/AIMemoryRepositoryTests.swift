import Foundation
import XCTest
@testable import CoupleChat

private actor AIMemoryHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int
    private(set) var request: URLRequest?

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

final class AIMemoryRepositoryTests: XCTestCase {
    func testFetchDecodesVisibleMemoryAndBuildsFilters() async throws {
        let body = Data(#"""
        {
          "items": [{
            "id": "mem_1", "layer": "event", "scope": "couple",
            "memoryKey": "trip", "subjects": ["xu", "si"], "speakers": ["xu"],
            "content": "一起去了海边", "category": "travel", "confidence": 0.9,
            "importance": 4, "occurredAt": null, "occurredEndAt": null,
            "validFrom": null, "validUntil": null, "status": "active",
            "supersedesId": null, "createdAt": 1000, "updatedAt": 2000,
            "evidenceCount": 2, "version": 7
          }],
          "stats": { "total": 1, "shared": 1, "private": 0, "byLayer": { "event": 1 } },
          "nextCursor": "cursor-2", "hasMore": true
        }
        """#.utf8)
        let client = AIMemoryHTTPClient(data: body)
        let repository = AIMemoryRepository(httpClient: client)

        let snapshot = try await repository.fetch(
            scope: .shared, layer: .event, query: "海边",
            subject: "both", status: .all, token: "token")

        XCTAssertEqual(snapshot.items.first?.content, "一起去了海边")
        XCTAssertEqual(snapshot.stats.shared, 1)
        XCTAssertEqual(snapshot.items.first?.version, 7)
        XCTAssertTrue(snapshot.hasMore)
        let request = await client.request
        let components = URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "scope" }?.value, "shared")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "layer" }?.value, "event")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "q" }?.value, "海边")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "subject" }?.value, "both")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "status" }?.value, "all")
    }

    func testUnauthorizedResponseIsReported() async {
        let client = AIMemoryHTTPClient(data: Data(#"{"error":"unauthorized"}"#.utf8), statusCode: 401)
        let repository = AIMemoryRepository(httpClient: client)

        do {
            _ = try await repository.fetch(scope: .all, layer: nil, query: "", token: "expired")
            XCTFail("Expected an unauthorized error")
        } catch let error as AIMemoryRepositoryError {
            XCTAssertEqual(error.localizedDescription, "登录已失效，请重新登录")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateConflictCarriesAuthoritativeMemory() async throws {
        let body = Data(#"""
        {"error":"version_conflict","item":{"id":"mem_1","layer":"event",
        "scope":"couple","memoryKey":"trip","subjects":["xu","si"],
        "speakers":["xu"],"content":"另一台设备的新内容","category":"travel",
        "confidence":0.9,"importance":5,"occurredAt":null,"occurredEndAt":null,
        "validFrom":null,"validUntil":null,"status":"active","supersedesId":null,
        "createdAt":1000,"updatedAt":3000,"evidenceCount":2,"version":8}}
        """#.utf8)
        let repository = AIMemoryRepository(
            httpClient: AIMemoryHTTPClient(data: body, statusCode: 409))

        do {
            _ = try await repository.update(
                "mem_1", content: "旧修改", importance: 4,
                baseVersion: 7, token: "token")
            XCTFail("Expected a version conflict")
        } catch AIMemoryRepositoryError.conflict(let current) {
            XCTAssertEqual(current.content, "另一台设备的新内容")
            XCTAssertEqual(current.version, 8)
        }
    }
}
