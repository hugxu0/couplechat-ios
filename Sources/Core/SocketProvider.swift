import Foundation
import SocketIO

/// 子 store 通过此协议访问 socket，避免对 ChatStore 的直接依赖。
protocol SocketProvider: AnyObject {
    var socket: SocketIOClient? { get }
    var isConnected: Bool { get }
    var sessionUsername: String? { get }
    func emit(_ event: String, _ items: SocketData...)
}
