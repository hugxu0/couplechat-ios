import Foundation

enum VoiceTranscriptStatus: String, Decodable, Equatable {
    case none
    case queued
    case processing
    case ready
    case failed
    case unavailable

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "pending", "queued": self = .queued
        case "processing": self = .processing
        case "completed", "ready": self = .ready
        case "failed": self = .failed
        case "unavailable": self = .unavailable
        default: self = .none
        }
    }
}

struct VoiceTranscript: Decodable, Equatable {
    let messageId: String
    let status: VoiceTranscriptStatus
    let text: String?
    let language: String?
    let confidence: Double?
    let errorMessage: String?
    let updatedAt: Int
    let version: Int

    private enum CodingKeys: String, CodingKey {
        case messageId, id, status, text, transcript, language, locale
        case confidence, errorMessage, error, updatedAt, version
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try box.decodeIfPresent(String.self, forKey: .messageId)
            ?? (try box.decodeIfPresent(String.self, forKey: .id)) ?? ""
        status = try box.decodeIfPresent(VoiceTranscriptStatus.self, forKey: .status)
            ?? ((try box.decodeIfPresent(String.self, forKey: .text)) == nil ? .none : .ready)
        text = try box.decodeIfPresent(String.self, forKey: .text)
            ?? (try box.decodeIfPresent(String.self, forKey: .transcript))
        language = try box.decodeIfPresent(String.self, forKey: .language)
            ?? (try box.decodeIfPresent(String.self, forKey: .locale))
        confidence = try box.decodeIfPresent(Double.self, forKey: .confidence)
        errorMessage = try box.decodeIfPresent(String.self, forKey: .errorMessage)
            ?? (try box.decodeIfPresent(String.self, forKey: .error))
        if let value = try? box.decode(Int.self, forKey: .updatedAt) { updatedAt = value }
        else if let value = try? box.decode(Double.self, forKey: .updatedAt) { updatedAt = Int(value) }
        else { updatedAt = 0 }
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    init(
        messageId: String,
        status: VoiceTranscriptStatus,
        text: String? = nil,
        language: String? = nil,
        confidence: Double? = nil,
        errorMessage: String? = nil,
        updatedAt: Int = 0,
        version: Int = 0
    ) {
        self.messageId = messageId
        self.status = status
        self.text = text
        self.language = language
        self.confidence = confidence
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
        self.version = version
    }

    static func processing(messageId: String) -> VoiceTranscript {
        VoiceTranscript(messageId: messageId, status: .processing)
    }
}
