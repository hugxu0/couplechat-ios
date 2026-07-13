import Foundation

/// 合并高频已读更新并保证每个频道的时间戳只单调递增。
@MainActor
final class ReadReceiptCoordinator {
    typealias Emitter = @MainActor (_ channel: ChatChannel, _ timestamp: Double) -> Bool

    private var pending: [String: Double] = [:]
    private var lastEmitted: [String: Double] = [:]
    private var flushTask: Task<Void, Never>?

    func mark(
        _ channel: ChatChannel,
        through timestamp: Double,
        isConnected: Bool,
        emit: @escaping Emitter
    ) {
        guard timestamp > 0 else { return }
        let key = channel.rawValue
        pending[key] = max(pending[key] ?? 0, timestamp)
        guard isConnected else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.emitPending(using: emit)
        }
    }

    func flush(isConnected: Bool, emit: Emitter) {
        flushTask?.cancel()
        flushTask = nil
        lastEmitted.removeAll()
        guard isConnected else { return }
        emitPending(using: emit)
    }

    func confirm(_ channel: ChatChannel, through timestamp: Double) {
        let key = channel.rawValue
        guard let pendingTimestamp = pending[key], timestamp >= pendingTimestamp else { return }
        pending.removeValue(forKey: key)
        lastEmitted.removeValue(forKey: key)
    }

    func pendingTimestamp(for channel: ChatChannel) -> Double? {
        pending[channel.rawValue]
    }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        lastEmitted.removeAll()
    }

    private func emitPending(using emit: Emitter) {
        for (rawChannel, timestamp) in pending {
            guard timestamp > (lastEmitted[rawChannel] ?? 0),
                  let channel = ChatChannel(rawValue: rawChannel),
                  emit(channel, timestamp) else { continue }
            lastEmitted[rawChannel] = timestamp
        }
    }
}
