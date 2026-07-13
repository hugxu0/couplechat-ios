import UIKit
import ImageIO

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

/// 时间线 reload 后只决定“位置如何保持”，不执行任何 UIKit 操作。
/// 把这条高风险规则保持为纯逻辑，后续拆分 TimelineController 时可直接复用测试。
enum ChatTimelineReloadDecision: Equatable {
    case forceLatest
    case restorePendingAnchor
    case restoreVisibleAnchor
    case followLatest
    case preservePosition

    static func decide(
        stickToLatest: Bool,
        hasPendingAnchor: Bool,
        hasValidPendingAnchor: Bool,
        hasValidVisibleAnchor: Bool,
        wasNearLatestBottom: Bool,
        lastMessageChanged: Bool,
        messageCountIncreased: Bool,
        wasShowingAIActivity: Bool
    ) -> ChatTimelineReloadDecision {
        // 发送操作会先清空输入框/媒体预览，这可能触发一次没有新增消息的 reload。
        // 保留贴底意图，直到乐观消息真正进入时间线后再消费。
        if stickToLatest, lastMessageChanged || messageCountIncreased {
            return .forceLatest
        }
        if hasPendingAnchor, hasValidPendingAnchor {
            return .restorePendingAnchor
        }
        if !hasPendingAnchor, !wasNearLatestBottom, hasValidVisibleAnchor {
            return .restoreVisibleAnchor
        }
        if wasNearLatestBottom,
           lastMessageChanged,
           messageCountIncreased || wasShowingAIActivity {
            return .followLatest
        }
        return .preservePosition
    }
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
    let confirmStatus: String?
    let confirmLabels: String?
    let pending: Bool
    let failed: Bool
    let transcriptStatus: String?
    let transcriptText: String?
    let transcriptExpanded: Bool

    static func key(
        message: ChatMessage,
        width: CGFloat,
        mine: Bool,
        groupedWithPrevious: Bool,
        highlighted: Bool,
        transcript: VoiceTranscript? = nil,
        transcriptExpanded: Bool = false
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
            confirmStatus: message.meta?.confirm?.status,
            confirmLabels: message.meta?.confirm.map(ChatTimelineMetrics.confirmationMarkdown),
            pending: message.pending,
            failed: message.failed,
            transcriptStatus: transcript?.status.rawValue,
            transcriptText: transcript?.text,
            transcriptExpanded: transcriptExpanded
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
    static let mediaSize = CGSize(width: 200, height: 230)
    static let fileHeight: CGFloat = 58
    static let voiceHeight: CGFloat = 32
    static let stickerSize = CGSize(width: 132, height: 132)
    static let confirmButtonHeight: CGFloat = 38

    static func messageHeight(
        for message: ChatMessage,
        containerWidth: CGFloat,
        groupedWithPrevious: Bool,
        transcript: VoiceTranscript? = nil,
        transcriptExpanded: Bool = false
    ) -> CGFloat {
        let topGap = groupedWithPrevious ? sameSenderTopGap : otherSenderTopGap
        let maxBubbleWidth = max(180, containerWidth * bubbleMaxWidthRatio)
        let contentWidth = maxBubbleWidth - bubbleHorizontalPadding * 2
        var contentHeight: CGFloat

        if message.id.hasPrefix("__ai_activity__") {
            contentHeight = 20
        } else if message.interactionPayload != nil {
            contentHeight = 42
        } else { switch message.type {
        case "image", "video":
            contentHeight = mediaContentHeight(for: message)
            if let caption = mediaCaption(for: message) {
                contentHeight += measureText(caption, font: .systemFont(ofSize: 15), width: contentWidth) + 14
            }
        case "sticker":
            contentHeight = stickerSize.height
        case "voice":
            contentHeight = voiceContentHeight(
                transcript: transcript,
                expanded: transcriptExpanded,
                width: contentWidth)
        case "file":
            contentHeight = fileHeight
        default:
            let bodyHeight = ChatMarkdownRenderer.boundingSize(
                for: message.displayText.isEmpty ? " " : message.displayText,
                font: .systemFont(ofSize: 17),
                width: contentWidth).height
            contentHeight = bodyHeight
        } }

        if let confirm = message.meta?.confirm {
            contentHeight += confirmationHeight(confirm, width: contentWidth) + 12
        }

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
        if message.id.hasPrefix("__ai_activity__") {
            return 58
        }
        if message.interactionPayload != nil {
            return ceil(min(maxBubbleWidth, 222))
        }
        if message.meta?.confirm != nil { return ceil(min(maxBubbleWidth, 300)) }
        let bodyWidth = measureTextWidth(text, font: .systemFont(ofSize: 17), maxWidth: available)
        let replyWidth = measureTextWidth(message.replyPreview ?? "", font: .systemFont(ofSize: 13), maxWidth: available)
        let contentWidth = min(maxBubbleWidth, max(bodyWidth, replyWidth) + bubbleHorizontalPadding * 2)
        return ceil(max(minBubbleWidth, contentWidth))
    }

    static func mediaBubbleWidth(
        for type: String,
        containerWidth: CGFloat,
        transcriptExpanded: Bool = false
    ) -> CGFloat {
        switch type {
        case "sticker": return stickerSize.width
        case "file": return min(containerWidth * bubbleMaxWidthRatio, 250)
        case "voice": return min(containerWidth * bubbleMaxWidthRatio, transcriptExpanded ? 276 : 218)
        default: return mediaSize.width
        }
    }

    static func mediaContentHeight(for message: ChatMessage) -> CGFloat {
        guard message.type == "image" || message.type == "video",
              let url = message.mediaURL else { return mediaSize.height }

        let size: CGSize?
        if let cached = ImageCache.shared.memoryImage(for: url) {
            size = cached.size
        } else if url.isFileURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            size = CGSize(width: width.doubleValue, height: height.doubleValue)
        } else {
            size = nil
        }
        guard let size, size.width > 0, size.height > 0 else {
            return mediaSize.height
        }
        let fittedHeight = mediaSize.width * size.height / size.width
        // 横图不再占用竖图的 230pt 高度；竖图仍保留原来的阅读尺寸。
        return floor(min(mediaSize.height, max(118, fittedHeight)))
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

    static func confirmationHeight(_ confirm: ActionConfirm, width: CGFloat) -> CGFloat {
        let itemsHeight = ChatMarkdownRenderer.boundingSize(
            for: confirmationMarkdown(confirm),
            font: .systemFont(ofSize: 14),
            width: width).height
        return 22 + 7 + itemsHeight + (confirm.status == "pending" ? 10 + confirmButtonHeight : 8 + 20)
    }

    static func confirmationMarkdown(_ confirm: ActionConfirm) -> String {
        confirm.items.map { item in
            let scope = item.action.scope == "shared"
                ? "共享"
                : (item.action.scope == "personal" ? "私人" : "未标明")
            var parts = ["**\(item.label)**", "范围：\(scope)"]
            if item.action.type == "add_memo", let text = item.action.text, !text.isEmpty {
                parts.append(text)
            } else if item.action.type == "edit_memo", let text = item.action.newText, !text.isEmpty {
                parts.append(text)
            }
            return parts.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    static func voiceContentHeight(
        transcript: VoiceTranscript?,
        expanded: Bool,
        width: CGFloat
    ) -> CGFloat {
        guard expanded,
              transcript?.status == .ready,
              let text = transcript?.text,
              !text.isEmpty else { return voiceHeight }
        let textHeight = measureText(text, font: .preferredFont(forTextStyle: .subheadline), width: width)
        return voiceHeight + 10 + textHeight + 30
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
