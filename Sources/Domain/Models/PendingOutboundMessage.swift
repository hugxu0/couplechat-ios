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
    /// `true` 表示自动重试已经结束；重连不能再次发送，必须由用户显式重试。
    var requiresManualRetry = false
    var metaJSON: String? = nil
    var attachments: [PendingOutboundAttachment] = []

    var isMedia: Bool {
        switch type {
        case "image", "video", "voice", "file": return true
        default: return !attachments.isEmpty
        }
    }

    func optimisticMessage(session: Session, waitingToSend: Bool = false) -> ChatMessage {
        let meta = decodedMeta
        if isMedia || type == "sticker" {
            let optimisticAttachments = attachments.map { attachment in
                ChatAttachment(
                    id: attachment.uploadId ?? "pending-\(attachment.assetId)-\(attachment.role)",
                    assetId: attachment.assetId,
                    role: attachment.role,
                    order: attachment.order,
                    url: attachment.uploadURL ?? URL(fileURLWithPath: attachment.localFilePath).absoluteString,
                    mimeType: attachment.mimeType)
            }
            var message = ChatMessage(
                optimisticMedia: type,
                text: text,
                localURL: localFilePath.map { URL(fileURLWithPath: $0).absoluteString } ?? uploadURL,
                me: session,
                clientId: clientId,
                channel: channel,
                attachments: optimisticAttachments.isEmpty ? nil : optimisticAttachments,
                meta: meta)
            message.ts = createdAt
            message.pending = !requiresManualRetry
            message.failed = requiresManualRetry
            message.waitingToSend = waitingToSend && !requiresManualRetry
            return message
        }

        var message = ChatMessage(
            optimisticText: text,
            me: session,
            clientId: clientId,
            channel: channel,
            replyTo: replyTo,
            replyPreview: replyPreview,
            meta: meta)
        message.ts = createdAt
        message.pending = !requiresManualRetry
        message.failed = requiresManualRetry
        message.waitingToSend = waitingToSend && !requiresManualRetry
        return message
    }

    private var decodedMeta: ChatMessageMeta? {
        guard let metaJSON,
              let data = metaJSON.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return ChatMessageMeta(dict: dictionary)
    }
}

struct PendingOutboundAttachment: Codable, Equatable {
    let assetId: String
    let role: String
    let order: Int
    let localFilePath: String
    let mimeType: String
    var uploadId: String?
    var uploadURL: String?
}
