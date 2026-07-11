import Foundation

actor OutboxProcessor {
    private let persistence: any ChatPersistenceProtocol
    private var flushing = false
    private var flushRequested = false

    init(persistence: any ChatPersistenceProtocol = ChatPersistence.shared) {
        self.persistence = persistence
    }

    func beginFlush() -> Bool {
        guard !flushing else {
            flushRequested = true
            return false
        }
        flushing = true
        flushRequested = false
        return true
    }

    func finishFlush() -> Bool {
        flushing = false
        let shouldRepeat = flushRequested
        flushRequested = false
        return shouldRepeat
    }

    func allPending() async -> [PendingOutboundMessage] {
        await persistence.loadPendingOutbounds()
    }

    func pending(clientId: String) async -> PendingOutboundMessage? {
        await persistence.pendingOutbound(clientId: clientId)
    }

    func save(_ item: PendingOutboundMessage) async -> Bool {
        await persistence.upsertPendingOutbound(item)
    }

    func remove(clientId: String) async -> PendingOutboundMessage? {
        let item = await persistence.pendingOutbound(clientId: clientId)
        await persistence.deletePendingOutbound(clientId: clientId)
        return item
    }
}
