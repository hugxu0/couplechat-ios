import Foundation

struct PendingMessageDraft {
    let message: ChatMessage
    let outbound: PendingOutboundMessage
}

/// 创建乐观消息和 outbox 项，保证文字、媒体与贴纸使用同一套 clientId/时间戳规则。
enum PendingMessageFactory {
    static func text(
        _ text: String,
        channel: ChatChannel,
        replyTo: String?,
        replyPreview: String?,
        meta: ChatMessageMeta?,
        session: Session,
        clientId requestedClientId: String? = nil
    ) -> PendingMessageDraft {
        let clientId = requestedClientId ?? makeClientId()
        let message = ChatMessage(
            optimisticText: text,
            me: session,
            clientId: clientId,
            channel: channel.rawValue,
            replyTo: replyTo,
            replyPreview: replyPreview,
            meta: meta)
        let outbound = PendingOutboundMessage(
            clientId: clientId,
            channel: channel.rawValue,
            type: "text",
            text: text,
            replyTo: replyTo,
            replyPreview: replyPreview,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: message.ts,
            attempts: 0,
            lastError: nil,
            metaJSON: encodedMeta(meta))
        return PendingMessageDraft(message: message, outbound: outbound)
    }

    static func media(
        type: String,
        text: String?,
        mimeType: String,
        durableURL: URL?,
        previewURL: URL?,
        channel: ChatChannel,
        session: Session,
        clientId requestedClientId: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970 * 1000
    ) -> PendingMessageDraft {
        let clientId = requestedClientId ?? makeClientId()
        let outgoingText = text ?? placeholderText(for: type)
        var message = ChatMessage(
            optimisticMedia: type,
            text: outgoingText,
            localURL: durableURL?.absoluteString ?? previewURL?.absoluteString,
            me: session,
            clientId: clientId,
            channel: channel.rawValue)
        message.ts = createdAt
        let outbound = PendingOutboundMessage(
            clientId: clientId,
            channel: channel.rawValue,
            type: type,
            text: outgoingText,
            replyTo: nil,
            replyPreview: nil,
            localFilePath: durableURL?.path,
            mimeType: mimeType,
            uploadId: nil,
            uploadURL: nil,
            createdAt: createdAt,
            attempts: 0,
            lastError: nil)
        return PendingMessageDraft(message: message, outbound: outbound)
    }

    static func sticker(
        url: String,
        channel: ChatChannel,
        session: Session,
        clientId requestedClientId: String? = nil
    ) -> PendingMessageDraft {
        let clientId = requestedClientId ?? makeClientId()
        let message = ChatMessage(
            optimisticMedia: "sticker",
            text: "[表情]",
            localURL: url,
            me: session,
            clientId: clientId,
            channel: channel.rawValue)
        let outbound = PendingOutboundMessage(
            clientId: clientId,
            channel: channel.rawValue,
            type: "sticker",
            text: "[表情]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: url,
            createdAt: message.ts,
            attempts: 0,
            lastError: nil)
        return PendingMessageDraft(message: message, outbound: outbound)
    }

    static func placeholderText(for type: String) -> String {
        switch type {
        case "video": return "[视频]"
        case "voice": return "[语音]"
        case "file": return "[文件]"
        default: return "[图片]"
        }
    }

    private static func makeClientId() -> String {
        "tmp-" + UUID().uuidString
    }

    private static func encodedMeta(_ meta: ChatMessageMeta?) -> String? {
        guard let meta, let data = try? JSONEncoder().encode(meta) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
