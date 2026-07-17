import Foundation
import SocketIO
import UIKit
import XCTest
@testable import CoupleChat

private final class HardeningDisconnectedSocketProvider: SocketProvider {
    var socket: SocketIOClient? { nil }
    var isConnected: Bool { false }
    var sessionUsername: String? { "xu" }
    var currentSession: Session? { Session(token: "token", username: "xu", name: "小旭") }
}

@MainActor
final class ClientHardeningTests: XCTestCase {
    func testOfflineReadReceiptKeepsHighestTimestampUntilReconnect() {
        let store = MessageStore()
        let provider = HardeningDisconnectedSocketProvider()
        store.socketProvider = provider

        store.markRead(.couple, through: 200)
        store.markRead(.couple, through: 100)
        store.markRead(.couple, through: 350)
        store.flushPendingReadReceipts()

        XCTAssertEqual(store.pendingReadTimestamp(for: .couple), 350)
    }

    func testRecallRemovesMessageAndScrubsReplyReferenceInMemory() async {
        let target = message(id: "removed", text: "原文")
        let reply = message(
            id: "reply",
            text: "回复",
            replyTo: "removed",
            replyPreview: "原文")
        let persistence = ChatPersistence.shared
        let opened = await persistence.open(
            username: "hardening-recall-\(UUID().uuidString)")
        XCTAssertTrue(opened)
        let databaseURL = await persistence.currentDatabaseURL()
        let inserted = await persistence.insertMessages([target, reply])
        XCTAssertEqual(inserted, 2)

        let store = MessageStore(persistence: persistence)
        store.updateMessages(.couple) { $0 = [target, reply] }
        let notification = expectation(
            forNotification: MessageStore.messageDeletedNotification,
            object: nil) { note in
                note.userInfo?["messageId"] as? String == "removed"
            }

        let recalled = await store.applyRecall(id: "removed", channel: .couple)

        XCTAssertTrue(recalled)
        await fulfillment(of: [notification], timeout: 0.1)
        XCTAssertEqual(store.messages(for: .couple).map(\.id), ["reply"])
        XCTAssertNil(store.messages(for: .couple).first?.replyTo)
        XCTAssertNil(store.messages(for: .couple).first?.replyPreview)

        await persistence.close()
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }
    }

    func testMemoryImportanceIsPreservedWhenToggleMeaningDidNotChange() {
        XCTAssertEqual(AIMemoryDetailView.resolvedImportance(original: 1, isImportant: false), 1)
        XCTAssertEqual(AIMemoryDetailView.resolvedImportance(original: 4, isImportant: true), 4)
        XCTAssertEqual(AIMemoryDetailView.resolvedImportance(original: 2, isImportant: true), 5)
        XCTAssertEqual(AIMemoryDetailView.resolvedImportance(original: 5, isImportant: false), 3)
    }

    func testSessionDecodesFixedAccountResponse() throws {
        let decoder = JSONDecoder()
        let session = try decoder.decode(
            Session.self,
            from: Data(#"{"token":"t","username":"xu","name":"小旭","deviceId":"dev_1"}"#.utf8))

        XCTAssertEqual(session.username, "xu")
        XCTAssertEqual(session.deviceId, "dev_1")
    }

    func testNewServerErrorsHaveActionableMessages() {
        XCTAssertEqual(
            ServerErrorCode.message(for: "recall_window_expired", fallback: "fallback"),
            "消息发送超过 2 分钟，已经不能撤回")
        XCTAssertEqual(
            ServerErrorCode.message(for: "couple_required", fallback: "fallback"),
            "共享空间暂时不可用，请联系管理员")
    }

    func testEveryBuiltInWallpaperUsesDarkSurfaceToneInDarkAppearance() {
        for wallpaper in WallpaperChoice.allCases {
            let luminance = wallpaper.fallbackSurfaceLuminance(for: .dark)
            XCTAssertTrue(
                ChatSurfaceTone(luminance: luminance).usesLightContent,
                "\(wallpaper.rawValue) should use a dark bubble palette in dark appearance")
        }
    }

    func testNightWallpaperStaysDarkInLightAppearance() {
        XCTAssertTrue(ChatSurfaceTone(
            luminance: WallpaperChoice.night.fallbackSurfaceLuminance(for: .light)
        ).usesLightContent)
        XCTAssertFalse(ChatSurfaceTone(
            luminance: WallpaperChoice.aurora.fallbackSurfaceLuminance(for: .light)
        ).usesLightContent)
    }

    func testIncomingBubblePalettesKeepReadableContrast() {
        let lightPalette = ChatIncomingBubblePalette(darkSurface: false)
        let darkPalette = ChatIncomingBubblePalette(darkSurface: true)

        XCTAssertGreaterThan(
            contrastRatio(lightPalette.backgroundColor, lightPalette.primaryTextColor),
            7)
        XCTAssertGreaterThan(
            contrastRatio(darkPalette.backgroundColor, darkPalette.primaryTextColor),
            7)

        let darkTrait = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertFalse(lightPalette.primaryTextColor.isEqual(
            UIColor.label.resolvedColor(with: darkTrait)))
    }

    private func message(
        id: String,
        text: String = "媒体",
        channel: String = "couple",
        replyTo: String? = nil,
        replyPreview: String? = nil
    ) -> ChatMessage {
        var dictionary: [String: Any] = [
            "id": id,
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": "image",
            "text": text,
            "url": "/uploads/\(id).jpg",
            "channel": channel,
            "ts": 100,
        ]
        dictionary["replyTo"] = replyTo
        dictionary["replyPreview"] = replyPreview
        return ChatMessage(dict: dictionary)!
    }

    private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            guard component > 0.03928 else { return component / 12.92 }
            return CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
