import Foundation
import XCTest
@testable import CoupleChat

private actor V2FeatureHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int
    private(set) var request: URLRequest?

    init(_ json: String, statusCode: Int = 200) {
        data = Data(json.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

final class V2FeatureRepositoryTests: XCTestCase {
    func testAlbumsDecodeCompatibleFieldsAndCursor() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"albums":[{"id":"a1","title":"海边","summary":"第一次旅行","coverAssetId":"med1",
        "itemCount":2,"createdAt":1000,"updatedAt":2000,"version":3}]}
        """#)
        let page = try await MomentsRepository(httpClient: client).albums(
            cursor: "old", limit: 8, token: "token")

        XCTAssertEqual(page.values.first?.note, "第一次旅行")
        XCTAssertEqual(page.values.first?.itemCount, 2)
        XCTAssertEqual(page.values.first?.coverAssetId, "med1")
        XCTAssertEqual(page.values.first?.version, 3)
        XCTAssertNil(page.nextCursor)
        let request = await client.request
        XCTAssertEqual(request?.url?.path, "/api/v2/albums")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        let query = URLComponents(
            url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "cursor" }?.value, "old")
        XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "8")
    }

    func testAlbumItemsDecodeItemAndAssetIdentifiers() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"album":{"id":"a1","title":"海边","summary":"旅行","itemCount":1,
        "createdAt":1,"updatedAt":2,"version":4},"items":[{"id":"item1","addedAt":5,
        "asset":{"id":"med1","sourceMessageId":"m1","kind":"image","mimeType":"image/jpeg",
        "url":"/p.jpg","size":10,"takenAt":900,"createdAt":901,"version":2,
        "note":{"id":"n1","text":"海风很大","version":6}}}],"hasMore":false}
        """#)
        let result = try await MomentsRepository(httpClient: client).album(id: "a1", token: "token")

        XCTAssertEqual(result.1.values.first?.id, "med1")
        XCTAssertEqual(result.1.values.first?.albumItemId, "item1")
        XCTAssertEqual(result.1.values.first?.messageId, "m1")
        XCTAssertEqual(result.1.values.first?.caption, "海风很大")
        XCTAssertEqual(result.1.values.first?.noteVersion, 6)
        let request = await client.request
        XCTAssertEqual(request?.url?.path, "/api/v2/albums/a1/items")
    }

    func testCalendarDecodesAliasesAndSendsSharedScope() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"events":[{"id":"e1","scope":"private","title":"约会","notes":"看电影",
        "startAt":1000,"endAt":2000,"timezone":"Asia/Shanghai","allDay":false,
        "status":"completed","createdAt":1,"updatedAt":2,"version":7,"participants":[]}]}
        """#)
        let events = try await CalendarRepository(httpClient: client).events(
            monthContaining: Date(timeIntervalSince1970: 0), token: "token")

        XCTAssertEqual(events.first?.notes, "看电影")
        XCTAssertEqual(events.first?.startAt, 1000)
        XCTAssertEqual(events.first?.endAt, 2000)
        XCTAssertEqual(events.first?.isDone, true)
        XCTAssertEqual(events.first?.scope, "personal")
        XCTAssertEqual(events.first?.version, 7)
        let request = await client.request
        let query = URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "view" }?.value, "month")
        XCTAssertEqual(query?.first { $0.name == "month" }?.value, "1970-01")
        XCTAssertNotNil(query?.first { $0.name == "timezone" }?.value)
    }

    func testCalendarCreateMapsPersonalScopeAndRequiredEnd() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"event":{"id":"e2","scope":"private","title":"散步","notes":"","startAt":1000,
        "endAt":3601000,"timezone":"Asia/Shanghai","allDay":false,"status":"scheduled",
        "createdAt":1,"updatedAt":1,"version":0,"participants":[]}}
        """#)
        _ = try await CalendarRepository(httpClient: client).create(
            title: "散步", notes: "", startAt: 1000, endAt: nil,
            isAllDay: false, scope: "personal", token: "token")

        let request = await client.request
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any]
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(body?["scope"] as? String, "private")
        XCTAssertEqual(body?["endAt"] as? Int, 3_601_000)
        XCTAssertEqual(body?["allDay"] as? Bool, false)
        XCTAssertNotNil(body?["timezone"] as? String)
    }

    func testCalendarAllDayNormalizesToLocalMidnight() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let raw = Date(timeIntervalSince1970: 1_783_929_845)
        let startOfDay = calendar.startOfDay(for: raw)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: startOfDay))
        let client = V2FeatureHTTPClient(#"""
        {"event":{"id":"e3","scope":"shared","title":"纪念日","notes":"","startAt":1,
        "endAt":2,"timezone":"Asia/Shanghai","allDay":true,"status":"scheduled",
        "createdAt":1,"updatedAt":1,"version":0,"participants":[]}}
        """#)
        _ = try await CalendarRepository(httpClient: client).create(
            title: "纪念日", notes: "", startAt: Int(raw.timeIntervalSince1970 * 1_000),
            endAt: nil, isAllDay: true, scope: "shared", token: "token")

        let request = await client.request
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["startAt"] as? Int, Int(startOfDay.timeIntervalSince1970 * 1_000))
        XCTAssertEqual(body?["endAt"] as? Int, Int(nextDay.timeIntervalSince1970 * 1_000))
    }

    func testTranscriptFetchDecodesCompletedEnvelope() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"transcript":{"messageId":"m1","status":"completed","text":"晚上吃火锅","language":"zh-CN",
        "version":8,"updatedAt":1234}}
        """#)
        let fetched = try await VoiceTranscriptRepository(httpClient: client).fetch(
            messageId: "m1", token: "token")
        let transcript = try XCTUnwrap(fetched)

        XCTAssertEqual(transcript.messageId, "m1")
        XCTAssertEqual(transcript.status, .ready)
        XCTAssertEqual(transcript.text, "晚上吃火锅")
        XCTAssertEqual(transcript.language, "zh-CN")
        XCTAssertEqual(transcript.version, 8)
        let request = await client.request
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.path, "/api/v2/messages/m1/transcript")
    }

    func testTranscript404ReturnsNil() async throws {
        let client = V2FeatureHTTPClient(#"{"error":"not_found"}"#, statusCode: 404)
        let transcript = try await VoiceTranscriptRepository(httpClient: client).fetch(
            messageId: "missing", token: "token")
        XCTAssertNil(transcript)
    }


    func testTranscriptRetryUsesDedicatedRouteWithoutForceBody() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"transcript":{"messageId":"m1","status":"pending","text":"","version":2,"updatedAt":3}}
        """#)
        let transcript = try await VoiceTranscriptRepository(httpClient: client).retry(
            messageId: "m1", token: "token")

        XCTAssertEqual(transcript.status, .queued)
        let request = await client.request
        XCTAssertEqual(request?.url?.path, "/api/v2/messages/m1/transcript/retry")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertNil(request?.httpBody)
    }

    func testTranscriptRetryPreservesUnavailableStateFromLegacy503() async throws {
        let client = V2FeatureHTTPClient(#"""
        {"error":"transcription_unavailable","transcript":{"messageId":"m1",
        "status":"unavailable","text":"","errorMessage":"provider_not_configured",
        "version":2,"updatedAt":3}}
        """#, statusCode: 503)

        let transcript = try await VoiceTranscriptRepository(httpClient: client).retry(
            messageId: "m1", token: "token")

        XCTAssertEqual(transcript.status, .unavailable)
        XCTAssertEqual(transcript.errorMessage, "provider_not_configured")
    }

    func testTypedConflictsCarryAuthoritativeEntities() async throws {
        let albumClient = V2FeatureHTTPClient(#"""
        {"error":"version_conflict","album":{"id":"a1","title":"新标题","summary":"",
        "itemCount":0,"createdAt":1,"updatedAt":2,"version":9}}
        """#, statusCode: 409)
        let staleAlbum = MomentAlbum(id: "a1", title: "旧标题", version: 1)
        do {
            _ = try await MomentsRepository(httpClient: albumClient).updateAlbum(
                staleAlbum, title: "保存", summary: "", token: "token")
            XCTFail("expected album conflict")
        } catch V2RepositoryError.albumConflict(let current) {
            XCTAssertEqual(current.title, "新标题")
            XCTAssertEqual(current.version, 9)
        }

        let calendarClient = V2FeatureHTTPClient(#"""
        {"error":"version_conflict","event":{"id":"e1","scope":"shared",
        "title":"另一台设备的计划","notes":"","startAt":1000,"endAt":2000,
        "timezone":"Asia/Shanghai","allDay":false,"status":"scheduled",
        "createdAt":1,"updatedAt":3,"version":11,"participants":[]}}
        """#, statusCode: 409)
        let staleEvent = CalendarEvent(
            id: "e1", owner: "xu", scope: "shared", title: "旧计划",
            startAt: 1000, endAt: 2000, version: 1)
        do {
            _ = try await CalendarRepository(httpClient: calendarClient).update(
                staleEvent, title: "保存", notes: "", startAt: 1000,
                endAt: 2000, isAllDay: false, token: "token")
            XCTFail("expected calendar conflict")
        } catch V2RepositoryError.calendarConflict(let current) {
            XCTAssertEqual(current.title, "另一台设备的计划")
            XCTAssertEqual(current.version, 11)
        }
    }
}
