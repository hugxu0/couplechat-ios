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
    var metaJSON: String? = nil
    var attachments: [PendingOutboundAttachment] = []

    var isMedia: Bool {
        ["image", "video", "voice", "file"].contains(type) || !attachments.isEmpty
    }

    func optimisticMessage(session: Session) -> ChatMessage {
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
            let meta: ChatMessageMeta? = metaJSON.flatMap { raw in
                guard let data = raw.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return ChatMessageMeta(dict: dict)
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
            message.pending = attempts == 0
            message.failed = attempts > 0
            return message
        }

        let meta: ChatMessageMeta? = metaJSON.flatMap { raw in
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ChatMessageMeta(dict: dict)
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
        message.pending = attempts == 0
        message.failed = attempts > 0
        return message
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

struct OutboundMediaResource {
    let assetId: String
    let role: String
    let order: Int
    let data: Data
    let mimeType: String
}
