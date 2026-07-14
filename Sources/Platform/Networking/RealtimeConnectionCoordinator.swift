import Combine
import Foundation
import SocketIO

/// 实时连接的显示状态。过渡态不应被 UI 渲染为断联错误。
enum RealtimeConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed

    var isTransient: Bool {
        self == .connecting || self == .reconnecting
    }

    var isUnavailable: Bool {
        self == .disconnected || self == .failed
    }
}

/// Owns Socket.IO lifecycle and connection state. Domain event routing remains outside
/// this type so chat, shared-state, and AI handlers can migrate independently.
@MainActor
final class RealtimeConnectionCoordinator: ObservableObject, SocketProvider {
    @Published private(set) var state: RealtimeConnectionState = .disconnected
    @Published private(set) var lastError: String?

    private let baseURL: URL
    private let sessionProvider: () -> Session?
    private let onSocketCreated: (SocketIOClient) -> Void
    private let onConnected: () -> Void
    private let onUnauthorized: () -> Void

    private var manager: SocketManager?
    private(set) var socket: SocketIOClient?
    private var attemptInFlight = false
    private var attemptToken = UUID()
    private var reconnectAttempt = 0

    var isConnected: Bool { state == .connected }
    var sessionUsername: String? { sessionProvider()?.username }
    var currentSession: Session? { sessionProvider() }

    init(
        baseURL: URL = ServerConfig.baseURL,
        sessionProvider: @escaping () -> Session?,
        onSocketCreated: @escaping (SocketIOClient) -> Void,
        onConnected: @escaping () -> Void,
        onUnauthorized: @escaping () -> Void
    ) {
        self.baseURL = baseURL
        self.sessionProvider = sessionProvider
        self.onSocketCreated = onSocketCreated
        self.onConnected = onConnected
        self.onUnauthorized = onUnauthorized
    }

    func connect() {
        guard let session = sessionProvider() else { return }
        let createdSocket = socket == nil
        if createdSocket {
            let manager = SocketManager(socketURL: baseURL, config: [
                .compress,
                // iOS 前后台恢复由本协调器统一管理。关闭库内重连，避免两套
                // attempt/backoff 同时运行后互相把连接标记为“仍在进行”。
                .reconnects(false),
            ])
            self.manager = manager
            let socket = manager.defaultSocket
            self.socket = socket
            bindLifecycleEvents(socket)
            onSocketCreated(socket)
        }

        guard !isConnected, !attemptInFlight, let socket else { return }
        attemptInFlight = true
        state = createdSocket && state != .reconnecting ? .connecting : .reconnecting
        let token = UUID()
        attemptToken = token
        socket.connect(withPayload: ["token": session.token])
        scheduleTimeout(for: token)
    }

    func disconnect() {
        attemptToken = UUID()
        attemptInFlight = false
        reconnectAttempt = 0
        tearDownSocket()
        state = .disconnected
        lastError = nil
    }

    func forceReconnect() {
        attemptToken = UUID()
        attemptInFlight = false
        reconnectAttempt = 0
        tearDownSocket()
        state = .reconnecting
        connect()
    }

    func reportAway(_ away: Bool) {
        socket?.emit(SocketEvent.away.rawValue, away)
    }

    func setLastError(_ message: String?) {
        lastError = message
    }

    func verifyHealth() async -> Bool {
        if !isConnected {
            // 退避等待不应阻止用户主动回前台；connect() 会令旧 retry token 失效。
            if !attemptInFlight { connect() }
        }
        let deadline = Date().addingTimeInterval(2.4)
        while !isConnected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        guard isConnected, let socket else {
            forceReconnect()
            return false
        }
        let result: [Any] = await withCheckedContinuation { continuation in
            socket.emitWithAck(SocketEvent.health.rawValue).timingOut(after: 1.5) {
                continuation.resume(returning: $0)
            }
        }
        let healthy = (result.first as? [String: Any])?["ok"] as? Bool == true
        if !healthy { forceReconnect() }
        return healthy
    }

    private func bindLifecycleEvents(_ socket: SocketIOClient) {
        socket.on(clientEvent: .connect) { [weak self, weak socket] _, _ in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                self.attemptInFlight = false
                self.state = .connected
                self.reconnectAttempt = 0
                self.attemptToken = UUID()
                self.lastError = nil
                self.reportAway(false)
                self.onConnected()
            }
        }
        socket.on(clientEvent: .disconnect) { [weak self, weak socket] _, _ in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                guard self.sessionProvider() != nil else {
                    self.attemptInFlight = false
                    self.state = .disconnected
                    return
                }
                self.attemptToken = UUID()
                self.attemptInFlight = false
                self.socket = nil
                self.manager = nil
                self.state = .reconnecting
                self.scheduleRetry()
            }
        }
        socket.on(clientEvent: .error) { [weak self, weak socket] data, _ in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                self.handleError(data)
            }
        }
        socket.on(SocketEvent.connectError.rawValue) { [weak self, weak socket] data, _ in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                self.handleError(data)
            }
        }
    }

    private func scheduleTimeout(for token: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self,
                  self.attemptToken == token,
                  !self.isConnected,
                  self.sessionProvider() != nil else { return }
            self.attemptInFlight = false
            self.attemptToken = UUID()
            self.tearDownSocket()
            self.state = .reconnecting
            self.scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard sessionProvider() != nil else {
            state = .disconnected
            return
        }
        reconnectAttempt += 1
        let delay = Self.retryDelay(for: reconnectAttempt)
        let token = UUID()
        attemptToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  self.attemptToken == token,
                  !self.isConnected,
                  self.sessionProvider() != nil else { return }
            self.attemptInFlight = false
            self.connect()
        }
    }

    static func retryDelay(for attempt: Int) -> TimeInterval {
        switch max(1, attempt) {
        case 1: return 0.35
        case 2: return 0.7
        case 3: return 1.4
        case 4: return 2.4
        default: return 3
        }
    }

    private func tearDownSocket() {
        // 先解除“当前 socket”身份，再 disconnect；即使库同步回调 disconnect，
        // 旧实例也无法重新改写新连接的状态。
        let previousSocket = socket
        let previousManager = manager
        socket = nil
        manager = nil
        previousSocket?.disconnect()
        withExtendedLifetime(previousManager) {}
    }

    private func handleError(_ data: [Any]) {
        let message = data.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let error = item as? Error { return error.localizedDescription }
            if let dictionary = item as? [String: Any] {
                return dictionary.values.map { "\($0)" }.joined(separator: " ")
            }
            return "\(item)"
        }.joined(separator: " ")

        if message.lowercased().contains("unauthorized") {
            attemptInFlight = false
            state = .failed
            lastError = "登录已过期，请重新登录"
            onUnauthorized()
        } else {
            attemptToken = UUID()
            attemptInFlight = false
            tearDownSocket()
            state = .reconnecting
            lastError = nil
            scheduleRetry()
        }
    }
}
