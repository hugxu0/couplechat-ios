import Foundation

/// iOS 端 Socket.IO 协议入口。
/// 服务端事件名或字段变化时，先更新此文件与 server/src/contracts/realtime.ts，
/// 再改调用点，避免字符串散落在功能代码中。
enum SocketEvent: String {
    case connectError = "connect_error"
    case health
    case away
    case presence
    case messageSend = "message:send"
    case messageNew = "message:new"
    case messageRecall = "message:recall"
    case messageRecalled = "message:recalled"
    case messageUpdate = "message:update"
    case messagesSearch = "messages:search"
    case read
    case readUpdate = "read:update"
    case sharedSet = "shared:set"
    case sharedUpdate = "shared:update"
    case actionConfirm = "action:confirm"
    case aiTyping = "ai:typing"
    case aiReplying = "ai:replying"
    case aiActivity = "ai:activity"
    case personalItemChanged = "personalItem:changed"
}

struct MessagePageRequest {
    let channel: String
    let since: Double?
    let after: Double?
    let before: Double?
    let around: Double?
    let limit: Int

    init(channel: ChatChannel, since: Double? = nil, after: Double? = nil,
         before: Double? = nil, around: Double? = nil, limit: Int) {
        self.channel = channel.rawValue
        self.since = since
        self.after = after
        self.before = before
        self.around = around
        self.limit = limit
    }
}

struct MessageSearchCursor: Codable, Equatable {
    let ts: Double
    let id: String
}

struct MessageSearchPage {
    let messages: [ChatMessage]
    let nextCursor: MessageSearchCursor?
    let hasMore: Bool
}

struct MessageSearchRequest: Encodable {
    let channel: String
    let query: String
    let limit: Int
    let cursor: MessageSearchCursor?

    init(channel: ChatChannel, query: String, limit: Int, cursor: MessageSearchCursor? = nil) {
        self.channel = channel.rawValue
        self.query = query
        self.limit = limit
        self.cursor = cursor
    }
}

struct MessageSendRequest: Encodable {
    let channel: String
    let type: String
    let text: String
    let url: String?
    let uploadId: String?
    let replyTo: String?
    let replyPreview: String?
    let clientId: String
    let meta: MessageSendMeta?
    let attachments: [MessageAttachmentRequest]?

    init(channel: ChatChannel, type: String, text: String, url: String? = nil, uploadId: String? = nil,
         replyTo: String? = nil, replyPreview: String? = nil, clientId: String,
         meta: MessageSendMeta? = nil, attachments: [MessageAttachmentRequest]? = nil) {
        self.channel = channel.rawValue
        self.type = type
        self.text = text
        self.url = url
        self.uploadId = uploadId
        self.replyTo = replyTo
        self.replyPreview = replyPreview
        self.clientId = clientId
        self.meta = meta
        self.attachments = attachments
    }
}

struct MessageSendMeta: Encodable {
    let interaction: ChatInteractionMeta?
}

struct MessageAttachmentRequest: Encodable {
    let assetId: String
    let role: String
    let uploadId: String
    let order: Int
}

struct MessageRecallRequest: Encodable {
    let id: String
}

struct ActionConfirmRequest: Encodable {
    let messageId: String
    let decision: String
}

struct ReadReceiptRequest: Encodable {
    let channel: String
    let ts: Double

    init(channel: ChatChannel, ts: Double) {
        self.channel = channel.rawValue
        self.ts = ts
    }
}

enum SocketPayloadEncoder {
    static func encode<T: Encodable>(_ value: T) -> [String: Any] {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            assertionFailure("Socket payload 编码失败: \(error.localizedDescription)")
            return [:]
        }
    }
}
