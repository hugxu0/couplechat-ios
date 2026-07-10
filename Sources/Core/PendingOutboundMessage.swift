import Foundation

/// 本地发送队列中的一项。`clientId` 同时是服务端幂等键，重试时绝不能更换。
struct PendingOutboundMessage: Equatable {
    let clientId: String
    let channel: String
    var type: String
    let text: String
    let replyTo: String?
    let replyPreview: String?
    let localFilePath: String?
    let mimeType: String?
    var uploadId: String?
    var uploadURL: String?
    let createdAt: Double
    var attempts: Int
    var lastError: String?

    var isMedia: Bool {
        ["image", "video", "voice", "file"].contains(type)
    }

    func optimisticMessage(session: Session) -> ChatMessage {
        if isMedia || type == "sticker" {
            var message = ChatMessage(
                optimisticMedia: type,
                text: text,
                localURL: localFilePath.map { URL(fileURLWithPath: $0).absoluteString } ?? uploadURL,
                me: session,
                clientId: clientId,
                channel: channel)
            message.ts = createdAt
            message.pending = attempts == 0
            message.failed = attempts > 0
            return message
        }

        var message = ChatMessage(
            optimisticText: text,
            me: session,
            clientId: clientId,
            channel: channel,
            replyTo: replyTo,
            replyPreview: replyPreview)
        message.ts = createdAt
        message.pending = attempts == 0
        message.failed = attempts > 0
        return message
    }
}
