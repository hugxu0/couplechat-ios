import Foundation
import SocketIO

/// Routes domain Socket.IO events to the owning stores.
/// Connection lifecycle remains in RealtimeConnectionCoordinator.
@MainActor
final class RealtimeEventRouter {
    private let auth: AuthStore
    private let messageStore: MessageStore
    private let shared: SharedStore
    private let socketProvider: () -> SocketIOClient?
    private let setAIActivity: (String, AIActivity?) -> Void
    private let setPartnerOnline: (Bool) -> Void
    private let setPresenceKnown: (Bool) -> Void

    init(
        auth: AuthStore,
        messageStore: MessageStore,
        shared: SharedStore,
        socketProvider: @escaping () -> SocketIOClient?,
        setAIActivity: @escaping (String, AIActivity?) -> Void,
        setPartnerOnline: @escaping (Bool) -> Void,
        setPresenceKnown: @escaping (Bool) -> Void
    ) {
        self.auth = auth
        self.messageStore = messageStore
        self.shared = shared
        self.socketProvider = socketProvider
        self.setAIActivity = setAIActivity
        self.setPartnerOnline = setPartnerOnline
        self.setPresenceKnown = setPresenceKnown
    }

    func bind(_ s: SocketIOClient) {
        bindNewMessage(s)
        bindReadUpdate(s)
        bindMessageRecall(s)
        bindMessageUpdate(s)
        bindAITyping(s)
        bindAIReplying(s)
        bindAIActivity(s)
        bindPresence(s)
        bindSharedUpdate(s)
        bindPersonalItemChanged(s)
    }

    private func bindNewMessage(_ s: SocketIOClient) {
        s.on(SocketEvent.messageNew.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let msg = MessageStore.parseMessage(dict, context: "message:new") else { return }
            Task { @MainActor in
                guard let self else { return }
                let channel = ChatChannel(rawValue: msg.channel) ?? .couple
                self.messageStore.upsert(msg, in: channel)
                if msg.sender == "ai" {
                    self.setAIActivity(channel.rawValue, nil)
                }
                if channel == .ai {
                    self.messageStore.aiTyping = false
                    self.messageStore.aiReplying = false
                }
            }
        }
    }

    private func bindReadUpdate(_ s: SocketIOClient) {
        s.on(SocketEvent.readUpdate.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let user = dict["user"] as? String,
                  let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return }
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            Task { @MainActor in self?.messageStore.setReadState(channel, user: user, ts: ts) }
        }
    }

    private func bindMessageRecall(_ s: SocketIOClient) {
        s.on(SocketEvent.messageRecalled.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "")
            Task { @MainActor in
                self?.messageStore.applyRecall(id: id, channel: channel)
            }
        }
    }

    private func bindMessageUpdate(_ s: SocketIOClient) {
        s.on(SocketEvent.messageUpdate.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let metaDict = dict["meta"] as? [String: Any]
            Task { @MainActor in self?.messageStore.applyMessageUpdate(id: id, meta: metaDict) }
        }
    }

    private func bindAITyping(_ s: SocketIOClient) {
        s.on(SocketEvent.aiTyping.rawValue) { [weak self] data, _ in
            let typing = (data.first as? Bool) ?? true
            Task { @MainActor in self?.messageStore.aiTyping = typing }
        }
    }

    private func bindAIReplying(_ s: SocketIOClient) {
        s.on(SocketEvent.aiReplying.rawValue) { [weak self] data, _ in
            let replying = (data.first as? Bool) ?? true
            Task { @MainActor in self?.messageStore.aiReplying = replying }
        }
    }

    private func bindAIActivity(_ s: SocketIOClient) {
        s.on(SocketEvent.aiActivity.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let rawChannel = dict["channel"] as? String,
                  let channel = ChatChannel(rawValue: rawChannel),
                  let phase = dict["phase"] as? String else { return }
            let activity = AIActivity(
                channel: channel,
                requestMessageId: dict["requestMessageId"] as? String,
                requesterUsername: dict["requesterUsername"] as? String,
                phase: phase)
            Task { @MainActor in
                guard let self else { return }
                guard self.socketProvider() === s else { return }
                if activity.isVisible {
                    self.setAIActivity(channel.rawValue, activity)
                } else {
                    self.setAIActivity(channel.rawValue, nil)
                }
            }
        }
    }

    private func bindPresence(_ s: SocketIOClient) {
        s.on(SocketEvent.presence.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let online = dict["online"] as? [String] else { return }
            Task { @MainActor in
                guard let self, let me = self.auth.session else { return }
                self.setPartnerOnline(online.contains { $0 != me.username })
                self.setPresenceKnown(true)
            }
        }
    }

    private func bindSharedUpdate(_ s: SocketIOClient) {
        s.on(SocketEvent.sharedUpdate.rawValue) { [weak self] data, _ in
            guard let update = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.shared.applySharedUpdate(update) }
        }
    }

    private func bindPersonalItemChanged(_ s: SocketIOClient) {
        s.on(SocketEvent.personalItemChanged.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let itemDict = dict["item"] as? [String: Any],
                  let action = dict["action"] as? String else { return }
            if dict["source"] as? String == "ai" {
                NotificationCenter.default.post(
                    name: PersonalItemsRepository.changedNotification,
                    object: nil,
                    userInfo: ["action": action, "item": itemDict])
                return
            }
            let scope = itemDict["scope"] as? String ?? "personal"
            guard scope == "shared" else { return }
            Task { @MainActor in
                guard let self else { return }
                let itemOwner = itemDict["owner"] as? String ?? ""
                if itemOwner != self.auth.session?.username {
                    NotificationCenter.default.post(
                        name: SharedStore.personalItemChangedNotification,
                        object: nil,
                        userInfo: ["action": action, "item": itemDict])
                }
            }
        }
    }
}
