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
                .reconnects(true),
                .reconnectWaitMax(5),
            ])
            self.manager = manager
            let socket = manager.defaultSocket
            self.socket = socket
            bindLifecycleEvents(socket)
            onSocketCreated(socket)
        }

        guard !isConnected, !attemptInFlight, let socket else { return }
        attemptInFlight = true
        state = createdSocket ? .connecting : .reconnecting
        let token = UUID()
        attemptToken = token
        socket.connect(withPayload: ["token": session.token])
        scheduleTimeout(for: token)
    }

    func disconnect() {
        attemptToken = UUID()
        attemptInFlight = false
        reconnectAttempt = 0
        socket?.disconnect()
        manager = nil
        socket = nil
        state = .disconnected
        lastError = nil
    }

    func forceReconnect() {
        attemptToken = UUID()
        attemptInFlight = false
        reconnectAttempt = 0
        socket?.disconnect()
        manager = nil
        socket = nil
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
        if !isConnected { connect() }
        let deadline = Date().addingTimeInterval(2.2)
        while !isConnected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        guard isConnected, let socket else { return false }
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
                self.attemptInFlight = true
                self.state = .reconnecting
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
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self,
                  self.attemptToken == token,
                  !self.isConnected,
                  self.sessionProvider() != nil else { return }
            self.attemptInFlight = false
            self.socket?.disconnect()
            self.manager = nil
            self.socket = nil
            self.state = .reconnecting
            self.reconnectAttempt += 1
            let delay = min(5.0, pow(1.7, Double(self.reconnectAttempt)) * 0.35)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.attemptInFlight = false
            self.connect()
        }
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
            attemptInFlight = true
            state = .reconnecting
            lastError = nil
        }
    }
}
