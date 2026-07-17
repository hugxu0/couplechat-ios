import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    var sender: String
    var senderName: String
    var kind: String
    var type: String
    var text: String
    var url: String?
    var channel: String
    var ts: Double
    var clientId: String?
    var recalledText: String?
    var replyTo: String?
    var replyPreview: String?
    var meta: ChatMessageMeta?
    var attachments: [ChatAttachment]?
    var transcript: VoiceTranscript?
    var pending = false
    var failed = false

    private enum CodingKeys: String, CodingKey {
        case id, sender, senderName, kind, type, text, url, channel, ts, clientId
        case recalledText, replyTo, replyPreview, meta, attachments, transcript, pending, failed
    }

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let rawChannel = dict["channel"] as? String,
              ChatChannel(rawValue: rawChannel) != nil else { return nil }
        self.id = id
        sender = dict["sender"] as? String ?? ""
        senderName = dict["senderName"] as? String ?? ""
        kind = dict["kind"] as? String ?? "user"
        type = dict["type"] as? String ?? "text"
        text = dict["text"] as? String ?? ""
        url = dict["url"] as? String
        channel = rawChannel
        if let value = dict["ts"] as? NSNumber {
            ts = value.doubleValue
        } else if let value = dict["ts"] as? Double {
            ts = value
        } else if let value = dict["ts"] as? Int {
            ts = Double(value)
        } else {
            ts = 0
        }
        clientId = dict["clientId"] as? String
        recalledText = dict["recalledText"] as? String
        replyTo = dict["replyTo"] as? String
        replyPreview = dict["replyPreview"] as? String
        if let metaDict = dict["meta"] as? [String: Any] {
            self.meta = ChatMessageMeta(dict: metaDict)
        } else {
            self.meta = nil
        }
        if let attachmentList = dict["attachments"] as? [[String: Any]] {
            let parsed = attachmentList.compactMap(ChatAttachment.init(dict:))
            attachments = parsed.isEmpty ? nil : parsed
        } else {
            attachments = nil
        }
        if let transcriptDict = dict["transcript"] as? [String: Any] {
            transcript = VoiceTranscript(dict: transcriptDict, fallbackMessageId: id)
        } else {
            transcript = nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let rawChannel = try container.decode(String.self, forKey: .channel)
        guard ChatChannel(rawValue: rawChannel) != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .channel,
                in: container,
                debugDescription: "Unsupported chat channel")
        }
        channel = rawChannel
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? ""
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "user"
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url)
        ts = try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        recalledText = try container.decodeIfPresent(String.self, forKey: .recalledText)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        replyPreview = try container.decodeIfPresent(String.self, forKey: .replyPreview)
        meta = try container.decodeIfPresent(ChatMessageMeta.self, forKey: .meta)
        attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments)
        transcript = try container.decodeIfPresent(VoiceTranscript.self, forKey: .transcript)
        pending = try container.decodeIfPresent(Bool.self, forKey: .pending) ?? false
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sender, forKey: .sender)
        try container.encode(senderName, forKey: .senderName)
        try container.encode(kind, forKey: .kind)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(channel, forKey: .channel)
        try container.encode(ts, forKey: .ts)
        try container.encodeIfPresent(clientId, forKey: .clientId)
        try container.encodeIfPresent(recalledText, forKey: .recalledText)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encodeIfPresent(replyPreview, forKey: .replyPreview)
        try container.encodeIfPresent(meta, forKey: .meta)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(pending, forKey: .pending)
        try container.encode(failed, forKey: .failed)
    }

    init(optimisticText text: String, me: Session, clientId: String, channel: String,
         replyTo: String? = nil, replyPreview: String? = nil, meta: ChatMessageMeta? = nil) {
        self.id = clientId
        self.clientId = clientId
        self.sender = me.username
        self.senderName = me.name
        self.kind = "user"
        self.type = "text"
        self.text = text
        self.url = nil
        self.channel = channel
        self.ts = Date().timeIntervalSince1970 * 1000
        self.pending = true
        self.replyTo = replyTo
        self.replyPreview = replyPreview
        self.meta = meta
        self.attachments = nil
        self.transcript = nil
    }

    init(optimisticMedia type: String, text: String, localURL: String?, me: Session, clientId: String, channel: String,
         attachments: [ChatAttachment]? = nil, meta: ChatMessageMeta? = nil) {
        self.id = clientId
        self.clientId = clientId
        self.sender = me.username
        self.senderName = me.name
        self.kind = "user"
        self.type = type
        self.text = text
        self.url = localURL
        self.channel = channel
        self.ts = Date().timeIntervalSince1970 * 1000
        self.pending = true
        self.meta = meta
        self.attachments = attachments
        self.transcript = nil
    }

    var date: Date { Date(timeIntervalSince1970: ts / 1000) }

    var mediaURL: URL? { ServerConfig.resolveMediaURL(url) }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

struct ChatMessageMeta: Codable, Equatable {
    var confirm: ActionConfirm?
    var search: SearchMeta?
    var interaction: ChatInteractionMeta?
    var recallNotice: RecallNoticeMeta?

    init?(dict: [String: Any]) {
        var hasAny = false
        if let confirmDict = dict["confirm"] as? [String: Any] {
            self.confirm = ActionConfirm(dict: confirmDict)
            hasAny = true
        } else {
            self.confirm = nil
        }
        if let searchDict = dict["search"] as? [String: Any] {
            self.search = SearchMeta(dict: searchDict)
            hasAny = true
        } else {
            self.search = nil
        }
        if let interactionDict = dict["interaction"] as? [String: Any] {
            self.interaction = ChatInteractionMeta(dict: interactionDict)
            hasAny = self.interaction != nil || hasAny
        } else {
            self.interaction = nil
        }
        if let recallDict = dict["recallNotice"] as? [String: Any] {
            recallNotice = RecallNoticeMeta(dict: recallDict)
            hasAny = recallNotice != nil || hasAny
        } else {
            recallNotice = nil
        }
        guard hasAny else { return nil }
    }

    init(interaction: ChatInteractionMeta) {
        confirm = nil
        search = nil
        self.interaction = interaction
        recallNotice = nil
    }
}

struct RecallNoticeMeta: Codable, Equatable {
    let messageId: String
    let by: String
    let byName: String

    init?(dict: [String: Any]) {
        guard let messageId = dict["messageId"] as? String,
              let by = dict["by"] as? String else { return nil }
        self.messageId = messageId
        self.by = by
        byName = dict["byName"] as? String ?? by
    }
}

struct ChatInteractionMeta: Codable, Equatable {
    let id: String
    let kind: String
    let text: String

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let kind = dict["kind"] as? String,
              let text = dict["text"] as? String else { return nil }
        self.id = id
        self.kind = kind
        self.text = text
    }

    init(id: String, kind: String, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

struct ChatAttachment: Identifiable, Codable, Equatable {
    let id: String
    let assetId: String
    let role: String
    let order: Int
    let url: String
    let mimeType: String
    let size: Int

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let assetId = dict["assetId"] as? String,
              let role = dict["role"] as? String,
              let url = dict["url"] as? String else { return nil }
        self.id = id
        self.assetId = assetId
        self.role = role
        self.order = (dict["order"] as? NSNumber)?.intValue ?? dict["order"] as? Int ?? 0
        self.url = url
        self.mimeType = dict["mimeType"] as? String ?? "application/octet-stream"
        self.size = (dict["size"] as? NSNumber)?.intValue ?? dict["size"] as? Int ?? 0
    }

    init(id: String, assetId: String, role: String, order: Int, url: String, mimeType: String, size: Int = 0) {
        self.id = id
        self.assetId = assetId
        self.role = role
        self.order = order
        self.url = url
        self.mimeType = mimeType
        self.size = size
    }

    var mediaURL: URL? { ServerConfig.resolveMediaURL(url) }
}

struct ActionConfirm: Codable, Equatable {
    var status: String
    var items: [ConfirmItem]
    var requesterName: String
    var requesterUsername: String
    var failed: Int?

    init?(dict: [String: Any]) {
        guard let status = dict["status"] as? String,
              let itemsArr = dict["items"] as? [[String: Any]] else { return nil }
        self.status = status
        self.items = itemsArr.compactMap { ConfirmItem(dict: $0) }
        if self.items.isEmpty { return nil }
        self.requesterName = dict["requesterName"] as? String ?? ""
        self.requesterUsername = dict["requesterUsername"] as? String ?? ""
        self.failed = dict["failed"] as? Int
    }
}

struct ConfirmItem: Codable, Equatable, Identifiable {
    var id: String { label }
    var action: AiAction
    var label: String

    init?(dict: [String: Any]) {
        guard let label = dict["label"] as? String,
              let actionDict = dict["action"] as? [String: Any] else { return nil }
        self.label = label
        self.action = AiAction(dict: actionDict)
    }
}

struct AiAction: Codable, Equatable, Hashable {
    var type: String
    var title: String?
    var text: String?
    var time: String?
    var id: String?
    var newText: String?
    var ownerName: String?
    var scope: String?

    init(dict: [String: Any]) {
        self.type = dict["type"] as? String ?? ""
        self.title = dict["title"] as? String
        self.text = dict["text"] as? String
        self.time = dict["time"] as? String
        self.id = dict["id"] as? String
        self.newText = dict["newText"] as? String
        self.ownerName = dict["ownerName"] as? String
        self.scope = dict["scope"] as? String
    }
}

struct SearchMeta: Codable, Equatable {
    var items: [SearchCitation]
    var ts: Int

    init?(dict: [String: Any]) {
        guard let itemsArr = dict["items"] as? [[String: Any]] else { return nil }
        self.items = itemsArr.compactMap { SearchCitation(dict: $0) }
        if self.items.isEmpty { return nil }
        self.ts = dict["ts"] as? Int ?? 0
    }
}

struct SearchCitation: Codable, Equatable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var siteName: String?
    var summary: String?

    init(dict: [String: Any]) {
        self.url = dict["url"] as? String ?? ""
        self.title = dict["title"] as? String ?? url
        self.siteName = dict["site_name"] as? String
        self.summary = dict["summary"] as? String
    }
}
