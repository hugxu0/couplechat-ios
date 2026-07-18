import Foundation

extension PendingOutboundMessage {
    func sendRequest(channel: ChatChannel) -> MessageSendRequest? {
        guard attachments.allSatisfy({ $0.uploadId != nil }) else { return nil }
        // Stickers are already uploaded assets referenced by URL. The sticker library stores
        // the server's compact relative path, while the realtime contract deliberately accepts
        // only an absolute URL. Do not route these through the local-media upload branch merely
        // because they have no uploadId; canonicalize the existing remote URL instead.
        let requestURL: String?
        if type == "sticker" {
            guard uploadId == nil,
                  let resolved = ServerConfig.resolveMediaURL(uploadURL),
                  resolved.scheme == "http" || resolved.scheme == "https"
            else { return nil }
            requestURL = resolved.absoluteString
        } else {
            requestURL = uploadURL
        }
        let attachmentRequests = attachments.isEmpty ? nil : attachments.compactMap { attachment in
            attachment.uploadId.map {
                MessageAttachmentRequest(
                    assetId: attachment.assetId,
                    role: attachment.role,
                    uploadId: $0,
                    order: attachment.order)
            }
        }
        let decodedMeta = metaJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ChatMessageMeta.self, from: $0) }
        let sendMeta = decodedMeta.flatMap { meta -> MessageSendMeta? in
            guard meta.interaction != nil || meta.media != nil else { return nil }
            return MessageSendMeta(interaction: meta.interaction, media: meta.media)
        }
        return MessageSendRequest(
            channel: channel,
            type: type,
            text: text,
            url: requestURL,
            uploadId: uploadId,
            replyTo: replyTo,
            replyPreview: replyPreview,
            clientId: clientId,
            meta: sendMeta,
            attachments: attachmentRequests)
    }
}
