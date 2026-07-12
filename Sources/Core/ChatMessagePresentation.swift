import Foundation

enum ChatMessageContentKind: String, Codable, Equatable {
    case text
    case image
    case video
    case sticker
    case voice
    case file
    case unknown

    init(rawType: String) {
        self = Self(rawValue: rawType) ?? .unknown
    }

    var previewText: String? {
        switch self {
        case .text, .unknown: return nil
        case .image: return "[图片]"
        case .video: return "[视频]"
        case .sticker: return "[表情]"
        case .voice: return "[语音]"
        case .file: return "[文件]"
        }
    }
}

extension ChatMessage {
    var contentKind: ChatMessageContentKind {
        ChatMessageContentKind(rawType: type)
    }

    var conversationalPreviewText: String {
        contentKind.previewText ?? displayText
    }

    var replyPreviewText: String {
        "\(senderName): \(conversationalPreviewText)"
    }
}
