import XCTest
@testable import CoupleChat

@MainActor
final class StickerStoreTests: XCTestCase {
    func testAccountsHaveIndependentLibraries() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = StickerStore(defaults: defaults)

        store.activate(username: "xu")
        store.completeInitialSync(personalLibrary: nil)
        store.add(url: "/uploads/xu.gif")

        store.activate(username: "yu")
        store.completeInitialSync(personalLibrary: nil)
        XCTAssertTrue(store.library.isEmpty)
        store.add(url: "/uploads/yu.gif")

        store.activate(username: "xu")
        XCTAssertEqual(store.library.map(\.url), ["/uploads/xu.gif"])
    }

    func testDeletingGroupKeepsStickersInLibrary() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = StickerStore(defaults: defaults)
        store.activate(username: "xu")
        store.completeInitialSync(personalLibrary: nil)
        let group = store.createGroup(name: "猫猫")
        store.add(url: "/uploads/cat.gif", groupId: group.id)

        store.deleteGroup(group)

        XCTAssertEqual(store.library.map(\.url), ["/uploads/cat.gif"])
        XCTAssertEqual(store.library.first?.groupId, StickerStore.defaultGroupId)
        XCTAssertTrue(store.sortedGroups.isEmpty)
    }

    func testOlderBootstrapDoesNotOverwriteSocketLibrary() throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let store = StickerStore(defaults: defaults)
        store.activate(username: "xu")
        store.applySyncedLibrary(payload(id: "socket", url: "/uploads/new.gif", addedAt: 20))

        store.completeInitialSync(
            personalLibrary: payload(id: "bootstrap", url: "/uploads/old.gif", addedAt: 10))

        XCTAssertEqual(store.library.map(\.url), ["/uploads/new.gif"])
    }

    func testConcurrentDeviceAdditionsAreMerged() throws {
        let defaultsA = try makeDefaults(suffix: "device-a")
        let defaultsB = try makeDefaults(suffix: "device-b")
        defer {
            defaultsA.removePersistentDomain(forName: defaultsSuiteName(suffix: "device-a"))
            defaultsB.removePersistentDomain(forName: defaultsSuiteName(suffix: "device-b"))
        }
        let storeA = StickerStore(defaults: defaultsA)
        let storeB = StickerStore(defaults: defaultsB)
        var payloadA: [String: Any]?
        var payloadB: [String: Any]?
        storeA.configureSync { payloadA = $0 }
        storeB.configureSync { payloadB = $0 }

        storeA.activate(username: "xu")
        storeB.activate(username: "xu")
        storeA.completeInitialSync(personalLibrary: nil)
        storeB.completeInitialSync(personalLibrary: nil)
        storeA.add(url: "/uploads/a.gif")
        storeB.add(url: "/uploads/b.gif")

        let staleA = try XCTUnwrap(payloadA)
        let staleB = try XCTUnwrap(payloadB)
        storeA.applySyncedLibrary(staleB)
        storeB.applySyncedLibrary(staleA)

        let expected: Set<String> = ["/uploads/a.gif", "/uploads/b.gif"]
        XCTAssertEqual(Set(storeA.library.map(\.url)), expected)
        XCTAssertEqual(Set(storeB.library.map(\.url)), expected)
    }

    func testRemoteDeletionCannotBeResurrectedByStaleDevicePayload() throws {
        let defaultsA = try makeDefaults(suffix: "device-a")
        let defaultsB = try makeDefaults(suffix: "device-b")
        defer {
            defaultsA.removePersistentDomain(forName: defaultsSuiteName(suffix: "device-a"))
            defaultsB.removePersistentDomain(forName: defaultsSuiteName(suffix: "device-b"))
        }
        let storeA = StickerStore(defaults: defaultsA)
        let storeB = StickerStore(defaults: defaultsB)
        var payloadA: [String: Any]?
        var payloadB: [String: Any]?
        storeA.configureSync { payloadA = $0 }
        storeB.configureSync { payloadB = $0 }
        let seed = payload(id: "shared", url: "/uploads/shared.gif", addedAt: 100)

        storeA.activate(username: "xu")
        storeB.activate(username: "xu")
        storeA.applySyncedLibrary(seed)
        storeB.applySyncedLibrary(seed)
        let stalePayload = try XCTUnwrap(payloadB)
        storeA.delete(try XCTUnwrap(storeA.library.first))
        let deletionPayload = try XCTUnwrap(payloadA)

        storeB.applySyncedLibrary(deletionPayload)
        storeA.applySyncedLibrary(stalePayload)

        XCTAssertTrue(storeA.library.isEmpty)
        XCTAssertTrue(storeB.library.isEmpty)
        let tombstones = try XCTUnwrap(payloadA?["itemTombstones"] as? [[String: Any]])
        XCTAssertEqual(tombstones.first?["url"] as? String, "/uploads/shared.gif")
    }

    private var defaultsSuiteName: String {
        "StickerStoreTests.\(name)"
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func defaultsSuiteName(suffix: String) -> String {
        "\(defaultsSuiteName).\(suffix)"
    }

    private func makeDefaults(suffix: String) throws -> UserDefaults {
        let suiteName = defaultsSuiteName(suffix: suffix)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func payload(id: String, url: String, addedAt: Double) -> [String: Any] {
        [
            "version": 3,
            "items": [[
                "id": id,
                "url": url,
                "groupId": "default",
                "addedAt": addedAt,
            ]],
            "groups": [],
        ]
    }
}
