import UIKit

enum ChatTimelineItem: Hashable {
    case time(id: String, text: String)
    case system(id: String, text: String)
    case message(id: String)

    var id: String {
        switch self {
        case .time(let id, _), .system(let id, _), .message(let id):
            return id
        }
    }
}

enum ChatInputState: Equatable {
    case idle
    case editing
    case emojiPanel
    case attachmentPicking
    case recording(cancelled: Bool)
    case mediaPreview
}

struct ChatMessageLayout: Hashable {
    let messageId: String
    let width: CGFloat
    let mine: Bool
    let groupedWithPrevious: Bool
    let highlighted: Bool
    let type: String
    let text: String
    let replyPreview: String?
    let pending: Bool
    let failed: Bool

    static func key(
        message: ChatMessage,
        width: CGFloat,
        mine: Bool,
        groupedWithPrevious: Bool,
        highlighted: Bool
    ) -> ChatMessageLayout {
        ChatMessageLayout(
            messageId: message.id,
            width: floor(width),
            mine: mine,
            groupedWithPrevious: groupedWithPrevious,
            highlighted: highlighted,
            type: message.type,
            text: message.displayText,
            replyPreview: message.replyPreview,
            pending: message.pending,
            failed: message.failed
        )
    }
}

enum ChatTimelineMetrics {
    static let horizontalInset: CGFloat = 7
    static let avatarSize: CGFloat = 36
    static let avatarGap: CGFloat = 5
    static let bubbleHorizontalPadding: CGFloat = 14
    static let bubbleVerticalPadding: CGFloat = 9
    static let bubbleMaxWidthRatio: CGFloat = 0.72
    static let bubbleMinHeight: CGFloat = 36
    static let sameSenderTopGap: CGFloat = 3
    static let otherSenderTopGap: CGFloat = 10
    static let statusOutsideWidth: CGFloat = 22
    static let statusOutsideGap: CGFloat = 2
    static let mediaSize = CGSize(width: 230, height: 260)
    static let fileHeight: CGFloat = 58
    static let voiceHeight: CGFloat = 36
    static let stickerSize = CGSize(width: 132, height: 132)

    static func messageHeight(
        for message: ChatMessage,
        containerWidth: CGFloat,
        groupedWithPrevious: Bool
    ) -> CGFloat {
        let topGap = groupedWithPrevious ? sameSenderTopGap : otherSenderTopGap
        let maxBubbleWidth = max(180, containerWidth * bubbleMaxWidthRatio)
        let contentWidth = maxBubbleWidth - bubbleHorizontalPadding * 2
        var contentHeight: CGFloat

        if message.interactionPayload != nil {
            contentHeight = 32
        } else { switch message.type {
        case "image", "video":
            contentHeight = mediaSize.height
            if let caption = mediaCaption(for: message) {
                contentHeight += measureText(caption, font: .systemFont(ofSize: 15), width: contentWidth) + 14
            }
        case "sticker":
            contentHeight = stickerSize.height
        case "voice":
            contentHeight = voiceHeight
        case "file":
            contentHeight = fileHeight
        default:
            let bodyHeight = measureText(
                message.displayText.isEmpty ? " " : message.displayText,
                font: .systemFont(ofSize: 17),
                width: contentWidth
            )
            contentHeight = bodyHeight
        } }

        if let reply = message.replyPreview, !reply.isEmpty {
            contentHeight += 36 + 7
        }

        let extraPadding: CGFloat
        switch message.type {
        case "image", "video", "sticker":
            extraPadding = message.replyPreview?.isEmpty == false ? bubbleVerticalPadding * 2 : 0
        default:
            extraPadding = bubbleVerticalPadding * 2
        }
        let bubbleHeight = max(bubbleMinHeight, contentHeight + extraPadding)
        return ceil(topGap + bubbleHeight + 2)
    }

    static func textBubbleWidth(for message: ChatMessage, containerWidth: CGFloat) -> CGFloat {
        let maxBubbleWidth = max(180, containerWidth * bubbleMaxWidthRatio)
        let minBubbleWidth: CGFloat = 58
        let available = maxBubbleWidth - bubbleHorizontalPadding * 2
        let text = message.displayText.isEmpty ? " " : message.displayText
        if message.interactionPayload != nil {
            return ceil(min(maxBubbleWidth, 164))
        }
        let bodyWidth = measureTextWidth(text, font: .systemFont(ofSize: 17), maxWidth: available)
        let replyWidth = measureTextWidth(message.replyPreview ?? "", font: .systemFont(ofSize: 13), maxWidth: available)
        let contentWidth = min(maxBubbleWidth, max(bodyWidth, replyWidth) + bubbleHorizontalPadding * 2)
        return ceil(max(minBubbleWidth, contentWidth))
    }

    static func mediaBubbleWidth(for type: String, containerWidth: CGFloat) -> CGFloat {
        switch type {
        case "sticker": return stickerSize.width
        case "file": return min(containerWidth * bubbleMaxWidthRatio, 250)
        case "voice": return 146
        default: return mediaSize.width
        }
    }

    static func mediaCaption(for message: ChatMessage) -> String? {
        guard message.type == "image" || message.type == "video" else { return nil }
        let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isImagePlaceholder = text == "[图片]"
            || text == "[实况照片]"
            || (text.hasPrefix("[") && text.hasSuffix("张图片]")
                && Int(text.dropFirst().dropLast(4)) != nil)
        guard !text.isEmpty, !isImagePlaceholder, text != "[视频]" else { return nil }
        return text
    }

    private static func measureText(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.height)
    }

    private static func measureTextWidth(_ text: String, font: UIFont, maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return min(maxWidth, ceil(rect.width))
    }
}

extension AccentChoice {
    var uiColor: UIColor {
        switch self {
        case .tangerine: return UIColor(red: 1.00, green: 0.45, blue: 0.20, alpha: 1)
        case .sakura: return UIColor(red: 0.96, green: 0.36, blue: 0.55, alpha: 1)
        case .ocean: return UIColor(red: 0.25, green: 0.52, blue: 0.95, alpha: 1)
        case .mint: return UIColor(red: 0.10, green: 0.65, blue: 0.50, alpha: 1)
        case .grape: return UIColor(red: 0.55, green: 0.38, blue: 0.92, alpha: 1)
        }
    }
}
