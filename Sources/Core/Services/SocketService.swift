import Foundation
import SocketIO

/// WebSocket 服务：管理 Socket.IO 连接和事件
@MainActor
final class SocketService: ObservableObject {
    static let baseURL = ServerConfig.baseURL
    
    @Published var connected = false
    @Published var lastConnectionError: String?
    
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    
    // 事件回调
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onNewMessage: (([String: Any]) -> Void)?
    var onPresence: (([String]) -> Void)?
    var onReadInit: (([String: Any]) -> Void)?
    var onReadUpdate: (([String: Any]) -> Void)?
    var onMessageRecalled: (([String: Any]) -> Void)?
    var onMessageUpdate: (([String: Any]) -> Void)?
    var onAiTyping: ((Bool) -> Void)?
    var onAiReplying: ((Bool) -> Void)?
    var onSharedInit: (([String: Any]) -> Void)?
    var onSharedUpdate: (([String: Any]) -> Void)?
    var onPersonalItemChanged: (([String: Any]) -> Void)?
    
    var isConnected: Bool { connected }
    
    // MARK: - 连接管理
    
    func connect(token: String) {
        let m = SocketManager(socketURL: Self.baseURL, config: [
            .compress,
            .reconnects(true),
            .reconnectWaitMax(5),
            .connectParams(["token": token]),
        ])
        
        manager = m
        let s = m.defaultSocket
        socket = s
        bindEvents(s)
        s.connect(withPayload: ["token": token])
    }
    
    func disconnect() {
        socket?.disconnect()
        manager = nil
        socket = nil
        connected = false
    }
    
    func reconnect(token: String) {
        disconnect()
        connect(token: token)
    }
    
    // MARK: - 事件发送
    
    func emit(_ event: String, _ items: Any...) {
        socket?.emit(event, items)
    }
    
    func emitWithAck(_ event: String, timeout: Double, _ items: Any..., callback: @escaping ([Any]) -> Void) {
        socket?.emitWithAck(event, items).timingOut(after: timeout) { data in
            callback(data)
        }
    }
    
    // MARK: - 事件绑定
    
    private func bindEvents(_ s: SocketIOClient) {
        s.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.connected = true
                self.lastConnectionError = nil
                self.onConnect?()
            }
        }
        
        s.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.connected = false
                self.onDisconnect?()
            }
        }
        
        s.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in self?.handleError(data) }
        }
        
        s.on("connect_error") { [weak self] data, _ in
            Task { @MainActor in self?.handleError(data) }
        }
        
        s.on("message:new") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onNewMessage?(dict) }
        }
        
        s.on("presence") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let online = dict["online"] as? [String] else { return }
            Task { @MainActor in self?.onPresence?(online) }
        }
        
        s.on("read:init") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onReadInit?(dict) }
        }
        
        s.on("read:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onReadUpdate?(dict) }
        }
        
        s.on("message:recalled") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onMessageRecalled?(dict) }
        }
        
        s.on("message:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onMessageUpdate?(dict) }
        }
        
        s.on("ai:typing") { [weak self] data, _ in
            let typing = (data.first as? Bool) ?? true
            Task { @MainActor in self?.onAiTyping?(typing) }
        }
        
        s.on("ai:replying") { [weak self] data, _ in
            let replying = (data.first as? Bool) ?? true
            Task { @MainActor in self?.onAiReplying?(replying) }
        }
        
        s.on("shared:init") { [weak self] data, _ in
            guard let state = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onSharedInit?(state) }
        }
        
        s.on("shared:update") { [weak self] data, _ in
            guard let update = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onSharedUpdate?(update) }
        }
        
        s.on("personalItem:changed") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.onPersonalItemChanged?(dict) }
        }
    }
    
    private func handleError(_ data: [Any]) {
        let message = data.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let error = item as? Error { return error.localizedDescription }
            if let dict = item as? [String: Any] { return dict.values.map { "\($0)" }.joined(separator: " ") }
            return "\(item)"
        }.joined(separator: " ")
        
        lastConnectionError = message.isEmpty ? "连接失败" : message
        connected = false
        
        // Socket 层 unauthorized 不直接登出：可能只是重连握手异常。
        if message.lowercased().contains("unauthorized") {
            // 由 ChatStore 处理登出逻辑
        }
    }
}
