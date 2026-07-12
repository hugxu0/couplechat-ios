import Foundation

@MainActor
final class ChatTimelineStore: ObservableObject {
    @Published var messagesByChannel: [String: [ChatMessage]] = [:]
    @Published var readStates: [String: [String: Double]] = [:]

    var loadingOlderChannels = Set<String>()
    var loadingNewerChannels = Set<String>()
    var latestPersistedMessageIDs: [String: String] = [:]

    func messages(for channel: ChatChannel) -> [ChatMessage] {
        messagesByChannel[channel.rawValue] ?? []
    }

    func updateMessages(
        _ channel: ChatChannel,
        _ transform: (inout [ChatMessage]) -> Void
    ) {
        var next = messagesByChannel
        var list = next[channel.rawValue] ?? []
        transform(&list)
        next[channel.rawValue] = list
        messagesByChannel = next
    }

    func reset() {
        messagesByChannel = [:]
        readStates = [:]
        loadingOlderChannels = []
        loadingNewerChannels = []
        latestPersistedMessageIDs = [:]
    }
}
