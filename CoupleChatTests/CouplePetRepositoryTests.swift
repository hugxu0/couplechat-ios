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

        XCTAssertEqual(snapshot.pet.name, "大橘")
        XCTAssertEqual(snapshot.pet.version, 7)
        XCTAssertEqual(snapshot.pet.today?.responses.count, 2)
        XCTAssertTrue(snapshot.pet.today?.isCompleted == true)
        XCTAssertEqual(snapshot.pet.today?.reward?.item?.name, "同心晚霞")
        XCTAssertEqual(snapshot.pet.today?.reward?.item?.quantity, 1)
        XCTAssertEqual(snapshot.pet.inventory.first?.name, "晚霞花瓶")
        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v2/pet")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pet-token")
    }

    func testRespondSendsVersionAndIdempotencyKey() async throws {
        let client = CouplePetHTTPClient(data: Self.snapshotData)
        let repository = CouplePetRepository(httpClient: client)

        _ = try await repository.respond(
            promptId: "prompt_today",
            text: "今天的天空是粉色",
            baseVersion: 7,
            token: "token",
            idempotencyKey: "response-once")

        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v2/pet/today/responses")
        XCTAssertEqual(body["promptId"] as? String, "prompt_today")
        XCTAssertEqual(body["baseVersion"] as? Int, 7)
        XCTAssertEqual(body["idempotencyKey"] as? String, "response-once")
    }

    func testConflictIsExposedForRefreshRecovery() async {
        let client = CouplePetHTTPClient(
            data: Data(#"{"error":"version_conflict"}"#.utf8), statusCode: 409)
        let repository = CouplePetRepository(httpClient: client)

        do {
            _ = try await repository.rename("橘子", baseVersion: 3, token: "token")
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
        "mood": 90,
        "coins": 5,
        "scene": {
          "id": "window_nook",
          "title": "窗边小窝",
          "artworkURL": null,
          "placedItemIds": ["collectible_sunset"]
        },
        "today": {
          "id": "prompt_today",
          "prompt": "今天抬头时，天空是什么颜色？",
          "responseType": "text",
          "status": "settled",
          "responses": [
            {
              "username": "xu",
              "displayName": "嘘嘘",
              "text": "淡蓝色",
              "respondedAt": 1783900800000
            },
            {
              "username": "si",
              "displayName": "思思",
              "text": "晚霞粉",
              "respondedAt": 1783900860000
            }
          ],
          "reward": {
            "experience": 10,
            "coins": 2,
            "item": {
              "id": "collectible_together",
              "name": "同心晚霞",
              "kind": "photo",
              "symbolName": "sun.horizon.fill"
            }
          }
        },
        "inventory": [{
          "id": "collectible_sunset",
          "name": "晚霞花瓶",
          "kind": "plant",
          "symbolName": "camera.macro",
          "unlockedAt": 1783900800000,
          "isPlaced": true,
          "quantity": 1
        }],
        "moments": [{
          "id": "moment_1",
          "title": "第一次共同回应",
          "detail": "两个人都留下了今天的颜色",
          "createdAt": 1783900800000
        }],
        "latestInteraction": null
      }
    }
    """#.utf8)
}

final class DajuLayoutTests: XCTestCase {
    func testLandscapeIPadKeepsSixtyFortyNookAndPanel() {
        let metrics = DajuLayoutMetrics.resolve(
            width: 1_024, height: 740, hasRegularHorizontalSizeClass: true)

        XCTAssertEqual(metrics.mode, .split)
        XCTAssertEqual(metrics.panelWidth, 409.6, accuracy: 0.1)
        XCTAssertEqual(metrics.sceneWidth, 600.4, accuracy: 0.1)
    }

    func testWideIPadCapsContentAndPanelWidth() {
        let metrics = DajuLayoutMetrics.resolve(
            width: 1_366, height: 1_024, hasRegularHorizontalSizeClass: true)

        XCTAssertEqual(metrics.totalContentWidth, 1_050)
        XCTAssertEqual(metrics.panelWidth, 420)
        XCTAssertEqual(metrics.sceneWidth, 616)
    }

    func testPhoneAndPortraitIPadUseStackedDrawer() {
        XCTAssertEqual(DajuLayoutMetrics.resolve(
            width: 390, height: 844, hasRegularHorizontalSizeClass: false).mode, .stacked)
        XCTAssertEqual(DajuLayoutMetrics.resolve(
            width: 834, height: 1_194, hasRegularHorizontalSizeClass: true).mode, .stacked)
    }

    func testPhoneLandscapeLeavesRoomForContentDrawer() {
        let metrics = DajuLayoutMetrics.resolve(
            width: 820, height: 390, hasRegularHorizontalSizeClass: false)

        XCTAssertEqual(metrics.mode, .stacked)
        XCTAssertEqual(metrics.stackedSceneHeight, 195, accuracy: 0.1)
    }
}
