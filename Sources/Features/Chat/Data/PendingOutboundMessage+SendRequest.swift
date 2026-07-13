import Foundation

extension PendingOutboundMessage {
    func sendRequest(channel: ChatChannel) -> MessageSendRequest? {
        guard attachments.allSatisfy({ $0.uploadId != nil }) else { return nil }
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
        let interaction = decodedMeta?.interaction
        return MessageSendRequest(
            channel: channel,
            type: type,
            text: text,
            url: uploadURL,
            uploadId: uploadId,
            replyTo: replyTo,
            replyPreview: replyPreview,
            clientId: clientId,
            meta: interaction.map { MessageSendMeta(interaction: $0) },
            attachments: attachmentRequests)
    }
}
