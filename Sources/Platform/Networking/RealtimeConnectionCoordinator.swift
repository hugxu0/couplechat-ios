import Combine
import Foundation
import Network
import OSLog
import SocketIO

private struct RealtimeNetworkPath: Equatable, Sendable {
    let isSatisfied: Bool
    let usesWiFi: Bool
    let usesCellular: Bool
    let usesWiredEthernet: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        usesWiFi = path.usesInterfaceType(.wifi)
        usesCellular = path.usesInterfaceType(.cellular)
        usesWiredEthernet = path.usesInterfaceType(.wiredEthernet)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsDNS = path.supportsDNS
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
    }
}

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
    private let onConnectionUnavailable: () -> Void
    private let onUnauthorized: () -> Void

    private var manager: SocketManager?
    private(set) var socket: SocketIOClient?
    private var attemptInFlight = false
    private var attemptToken = UUID()
    private var reconnectAttempt = 0
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "top.hoo66.realtime-network-path")
    private var lastNetworkPath: RealtimeNetworkPath?
    private let logger = Logger(subsystem: "com.hugxu0.couplechat.native", category: "Realtime")

    // 一次 Socket.IO 建连包含 TLS、Engine.IO polling、命名空间鉴权和可选的
    // WebSocket 升级。跨国弱网下不能用单次 HTTP 请求级别的超时衡量整条链路。
    private static let transportConnectionTimeout: TimeInterval = 12
    private static let namespaceConnectionGrace: TimeInterval = 8
    private static let foregroundConnectionWait: TimeInterval = 12
    private static let healthAckTimeout: TimeInterval = 5
    private static let visibleFailureAttempt = 3

    var isConnected: Bool { state == .connected }
    var sessionUsername: String? { sessionProvider()?.username }
    var currentSession: Session? { sessionProvider() }

    init(
        baseURL: URL = ServerConfig.baseURL,
        sessionProvider: @escaping () -> Session?,
        onSocketCreated: @escaping (SocketIOClient) -> Void,
        onConnected: @escaping () -> Void,
        onConnectionUnavailable: @escaping () -> Void = {},
        onUnauthorized: @escaping () -> Void
    ) {
        self.baseURL = baseURL
        self.sessionProvider = sessionProvider
        self.onSocketCreated = onSocketCreated
        self.onConnected = onConnected
        self.onConnectionUnavailable = onConnectionUnavailable
        self.onUnauthorized = onUnauthorized

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let snapshot = RealtimeNetworkPath(path)
            Task { @MainActor [weak self] in
                self?.handleNetworkPathChange(snapshot)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
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
        if reconnectAttempt < Self.visibleFailureAttempt {
            state = createdSocket && state != .reconnecting ? .connecting : .reconnecting
        }
        let token = UUID()
        attemptToken = token
        logger.info("Starting realtime connection attempt")
        socket.connect(withPayload: ["token": session.token])
        scheduleTimeout(
            for: token,
            after: Self.transportConnectionTimeout,
            allowsNamespaceGrace: true)
    }

    func disconnect() {
        attemptToken = UUID()
        attemptInFlight = false
        reconnectAttempt = 0
        tearDownSocket()
        state = .disconnected
        lastError = nil
        logger.info("Realtime connection stopped")
    }

    func forceReconnect() {
        attemptToken = UUID()
        attemptInFlight = false
        reconnectAttempt = 0
        tearDownSocket()
        state = .reconnecting
        lastError = nil
        onConnectionUnavailable()
        logger.info("Forcing realtime connection rebuild")
        connect()
    }

    func recoverConnection() {
        forceReconnect()
    }

    func reportAway(_ away: Bool) {
        socket?.emit(SocketEvent.away.rawValue, away)
    }

    func setLastError(_ message: String?) {
        lastError = message
    }

    func verifyHealth() async -> Bool {
        if !isConnected {
            // 正在进行的握手可能已通过 TLS/polling，不能因前台检查再次拆掉。
            if !attemptInFlight { connect() }
        }
        let deadline = Date().addingTimeInterval(Self.foregroundConnectionWait)
        while !isConnected, Date() < deadline {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        guard isConnected, let socket else {
            // 超时任务和退避状态机负责回收当前尝试；这里只触发缺失的尝试，
            // 避免健康检查与建连超时同时 forceReconnect 形成活锁。
            if !attemptInFlight { connect() }
            return false
        }
        let result: [Any] = await withCheckedContinuation { continuation in
            socket.emitWithAck(SocketEvent.health.rawValue).timingOut(after: Self.healthAckTimeout) {
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
                self.logger.info("Realtime connection established")
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
                self.onConnectionUnavailable()
                self.logger.info("Realtime connection closed; scheduling retry")
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

    private func scheduleTimeout(
        for token: UUID,
        after delay: TimeInterval,
        allowsNamespaceGrace: Bool
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self,
                  self.attemptToken == token,
                  !self.isConnected,
                  self.sessionProvider() != nil else { return }

            // Engine.IO 已打开说明 TLS/polling 已成功，剩下的是命名空间鉴权回包。
            // 给这一阶段独立宽限，不能把一个有进展的弱网连接当成死连接。
            if allowsNamespaceGrace, self.manager?.status == .connected {
                self.logger.info("Realtime transport opened; extending namespace handshake")
                self.scheduleTimeout(
                    for: token,
                    after: Self.namespaceConnectionGrace,
                    allowsNamespaceGrace: false)
                return
            }

            self.attemptInFlight = false
            self.attemptToken = UUID()
            self.tearDownSocket()
            self.state = .reconnecting
            self.onConnectionUnavailable()
            self.logger.info("Realtime connection attempt timed out; scheduling retry")
            self.scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard sessionProvider() != nil else {
            state = .disconnected
            return
        }
        reconnectAttempt += 1
        if reconnectAttempt >= Self.visibleFailureAttempt {
            state = .failed
            lastError = "连接暂时不可用，正在自动重试"
        }
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

    private func handleNetworkPathChange(_ current: RealtimeNetworkPath) {
        let previous = lastNetworkPath
        lastNetworkPath = current
        guard let previous, sessionProvider() != nil else { return }

        if !current.isSatisfied {
            attemptToken = UUID()
            attemptInFlight = false
            tearDownSocket()
            state = .failed
            lastError = "网络不可用，等待网络恢复"
            onConnectionUnavailable()
            logger.info("Network path unavailable; waiting for a usable path")
            return
        }

        // Wi-Fi / 蜂窝网络发生切换时，旧 socket 可能仍显示 connected，却已无法
        // 收到 ACK。主动换一条连接，建立成功后会自动重放本地 outbox。
        if previous != current || !isConnected {
            logger.info("Network path changed; rebuilding realtime connection")
            forceReconnect()
        } else {
            // NWPathMonitor 可能在 Wi-Fi 到 Wi-Fi 的路由变化中给出相同摘要。
            // 先探测现有连接，只有 ACK 丢失时才重建。
            Task { [weak self] in
                _ = await self?.verifyHealth()
            }
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
            onConnectionUnavailable()
            logger.info("Realtime connection error; scheduling retry")
            scheduleRetry()
        }
    }
}
