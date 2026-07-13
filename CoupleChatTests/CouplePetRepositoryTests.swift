import Foundation
import XCTest
@testable import CoupleChat

private actor CouplePetHTTPClient: HTTPClient {
    let data: Data
    let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
private struct OfflinePetHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

final class CouplePetRepositoryTests: XCTestCase {
    func testFetchDecodesSharedStateAndUsesV2Endpoint() async throws {
        let client = CouplePetHTTPClient(data: Self.snapshotData)
        let repository = CouplePetRepository(httpClient: client)

        let snapshot = try await repository.fetch(token: "pet-token")

        XCTAssertEqual(snapshot.pet.version, 7)
        XCTAssertEqual(snapshot.pet.satiety, 81)
        XCTAssertEqual(snapshot.pet.cleanliness, 88)
        XCTAssertEqual(snapshot.pet.energy, 100)
        XCTAssertEqual(snapshot.pet.latestInteraction?.kind, .stroke)
        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v2/pet")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pet-token")
    }

    func testInteractSendsVersionAndIdempotencyKey() async throws {
        let client = CouplePetHTTPClient(data: Self.snapshotData)
        let repository = CouplePetRepository(httpClient: client)

        _ = try await repository.interact(
            kind: .play,
            baseVersion: 7,
            token: "token",
            idempotencyKey: "response-once")

        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v2/pet/interactions")
        XCTAssertEqual(body["kind"] as? String, "play")
        XCTAssertEqual(body["baseVersion"] as? Int, 7)
        XCTAssertEqual(body["idempotencyKey"] as? String, "response-once")
    }

    func testConflictIsExposedForRefreshRecovery() async {
        let client = CouplePetHTTPClient(
            data: Data(#"{"error":"version_conflict"}"#.utf8), statusCode: 409)
        let repository = CouplePetRepository(httpClient: client)

        do {
            _ = try await repository.interact(kind: .stroke, baseVersion: 3, token: "token")
            XCTFail("Expected a version conflict")
        } catch let error as CouplePetRepositoryError {
            XCTAssertEqual(error, .conflict)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCoupleRequiredIsNotMisreportedAsVersionConflict() async {
        let client = CouplePetHTTPClient(
            data: Data(#"{"error":"couple_required"}"#.utf8), statusCode: 409)
        let repository = CouplePetRepository(httpClient: client)

        do {
            _ = try await repository.fetch(token: "token")
            XCTFail("Expected a server error")
        } catch let error as CouplePetRepositoryError {
            XCTAssertEqual(error, .server("couple_required"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSnapshotCacheIsPartitionedByAccount() throws {
        let suiteName = "CouplePetRepositoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = PetSnapshotCache(defaults: defaults)
        let snapshot = try JSONDecoder().decode(CouplePetSnapshot.self, from: Self.snapshotData)

        cache.save(snapshot, username: "xu")

        XCTAssertEqual(cache.load(username: "xu")?.pet.version, 7)
        XCTAssertNil(cache.load(username: "si"))
    }

    @MainActor
    func testViewModelKeepsCachedPetWhenRefreshFails() async throws {
        let suiteName = "CouplePetOfflineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = PetSnapshotCache(defaults: defaults)
        let snapshot = try JSONDecoder().decode(CouplePetSnapshot.self, from: Self.snapshotData)
        cache.save(snapshot, username: "xu")
        let repository = CouplePetRepository(httpClient: OfflinePetHTTPClient())
        let viewModel = DajuViewModel(repository: repository, cache: cache)

        await viewModel.load(token: "offline", username: "xu")

        XCTAssertEqual(viewModel.snapshot?.pet.version, 7)
        XCTAssertTrue(viewModel.usingCachedSnapshot)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    private static let snapshotData = Data(#"""
    {
      "pet": {
        "id": "pet_1",
        "name": "大橘",
        "version": 7,
        "level": 2,
        "experience": 44,
        "satiety": 81,
        "cleanliness": 88,
        "mood": 90,
        "energy": 100,
        "latestInteraction": {
          "id": "action_1",
          "kind": "stroke",
          "actorName": "嘘嘘",
          "createdAt": 1783900800000
        },
        "interactionCooldowns": []
      }
    }
    """#.utf8)
}
