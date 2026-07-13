import Foundation
import XCTest
@testable import CoupleChat

private actor RecordingHTTPClient: HTTPClient {
    private let dataToReturn: Data
    private let responseURL: URL
    private(set) var lastRequest: URLRequest?

    init(data: Data, responseURL: URL) {
        dataToReturn = data
        self.responseURL = responseURL
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (dataToReturn, response)
    }

    func recordedRequest() -> URLRequest? {
        lastRequest
    }
}

final class ChatRemoteDataSourceTests: XCTestCase {
    func testFetchMessagesBuildsAuthorizedPageRequest() async {
        let url = URL(string: "https://example.com/api/messages")!
        let body = Data("""
        {"list":[{"id":"m1","sender":"xu","senderName":"小旭","kind":"user","type":"text","text":"hello","channel":"couple","ts":100}]}
        """.utf8)
        let client = RecordingHTTPClient(data: body, responseURL: url)
        let source = ChatRemoteDataSource(httpClient: client)

        let messages = await source.fetchMessages(
            MessagePageRequest(channel: .couple, since: 42, limit: 24),
            session: Session(token: "token-1", username: "xu", name: "小旭"),
            context: "test")

        XCTAssertEqual(messages.map(\.id), ["m1"])
        let request = await client.recordedRequest()
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let components = request?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["channel"]!, "couple")
        XCTAssertEqual(query["since"]!, "42.0")
        XCTAssertEqual(query["limit"]!, "24")
    }

    func testFetchHistoryPageDecodesMessagesAndTotal() async {
        let url = URL(string: "https://example.com/api/messages")!
        let body = Data("""
        {"list":[{"id":"m2","sender":"si","senderName":"小偲","kind":"user","type":"text","text":"晚安","channel":"couple","ts":200}],"total":18}
        """.utf8)
        let client = RecordingHTTPClient(data: body, responseURL: url)
        let source = ChatRemoteDataSource(httpClient: client)

        let page = await source.fetchHistoryPage(
            channel: .couple,
            before: 500,
            limit: 300,
            session: Session(token: "token-2", username: "si", name: "小偲"))

        XCTAssertEqual(page.messages.map(\.id), ["m2"])
        XCTAssertEqual(page.total, 18)
        XCTAssertNil(page.error)
    }
}
