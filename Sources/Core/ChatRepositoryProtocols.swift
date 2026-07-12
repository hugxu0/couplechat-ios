import Foundation

@MainActor
protocol ChatRepositoryProtocol: AnyObject {
    var messagesByChannel: [String: [ChatMessage]] { get }
    var readStates: [String: [String: Double]] { get }

    func messages(for channel: ChatChannel) -> [ChatMessage]
    func restoreLocalCache(for session: Session) async
    func applyBootstrap(_ snapshot: AppBootstrapSnapshot, session: Session) async
    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage]
    func loadOlderAsync(_ channel: ChatChannel) async
    func loadNewerAsync(_ channel: ChatChannel) async
    func retryFailedMessage(clientId: String, session: Session) async -> OutboxRetryResult
    func discardFailedMessage(clientId: String) async
}

@MainActor
protocol OutboxProcessing: AnyObject {
    func flushOutbox(session: Session)
    func retryFailedMessage(clientId: String, session: Session) async -> OutboxRetryResult
    func discardFailedMessage(clientId: String) async
}
