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
            // 一帧左右合并同批 willDisplay 回调，避免逐条发包；用户侧仍近乎即时。
            try? await Task.sleep(nanoseconds: 40_000_000)
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

    /// 服务端已经持久化本次请求。即使服务端因消息撤回把 effectiveTs 向前截断，
    /// 也应按请求时间结束本次发送，避免同一个无效时间戳无限重试。
    func acknowledge(_ channel: ChatChannel, requestTimestamp: Double) {
        let key = channel.rawValue
        if let pendingTimestamp = pending[key], pendingTimestamp <= requestTimestamp {
            pending.removeValue(forKey: key)
        }
        if let emittedTimestamp = lastEmitted[key], emittedTimestamp <= requestTimestamp {
            lastEmitted.removeValue(forKey: key)
        }
    }

    /// ACK 超时或服务端拒绝时允许同一最高时间戳再次发送。重试仍经过 pending
    /// 合并，因此滚动期间不会倒退，也不会为每个 cell 建立独立重试循环。
    func retry(
        _ channel: ChatChannel,
        requestTimestamp: Double,
        isConnected: Bool,
        emit: @escaping Emitter
    ) {
        let key = channel.rawValue
        guard pending[key] != nil else { return }
        if lastEmitted[key] == requestTimestamp {
            lastEmitted.removeValue(forKey: key)
        }
        guard isConnected, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            self.emitPending(using: emit)
        }
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
