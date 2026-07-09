import Foundation
import XCTest
@testable import CoupleChat

private struct StubHTTPClient: HTTPClient {
    let dataToReturn: Data
    let responseToReturn: URLResponse

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (dataToReturn, responseToReturn)
    }
}

final class HTTPClientTests: XCTestCase {

    @MainActor
    func testAuthStoreUsesInjectedHTTPClient() async throws {
        let url = URL(string: "https://example.com/api/accounts")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let body = """
        [{"username":"xu","name":"小旭","avatar":"🐶"}]
        """.data(using: .utf8)!
        let store = AuthStore(httpClient: StubHTTPClient(dataToReturn: body, responseToReturn: response))

        let accounts = await store.fetchAccounts()

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.username, "xu")
        XCTAssertEqual(accounts.first?.name, "小旭")
    }
}
