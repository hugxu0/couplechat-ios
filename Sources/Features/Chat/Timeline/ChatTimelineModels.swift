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
        isHistoricalWindow: Bool = false
    ) -> ChatTimelineReloadDecision {
        // 历史窗口的 reload（搜索定位/向下分页）只允许恢复锚点；即使旧
        // offset 恰好落在旧窗口底部，也不能把新数据解释成“跟随最新”。
        if isHistoricalWindow {
            if hasPendingAnchor, hasValidPendingAnchor { return .restorePendingAnchor }
            if !hasPendingAnchor, hasValidVisibleAnchor { return .restoreVisibleAnchor }
            return .preservePosition
        }
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
        // pending 被 ACK 完整消息替换时，临时 id 会变成服务端 id，但消息总数
        // 不会增加。用户在替换前已经贴底，就必须继续跟随新的最后一项；否则
        // reloadData 保留旧 offset 后会错误出现“回到最新”，后续来信也不再上推。
        if wasNearLatestBottom, lastMessageChanged {
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
    let confirmActionable: Bool
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
        currentUsername: String?,
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
            confirmActionable: message.meta?.confirm.map {
                ChatTimelineMetrics.canDecideConfirmation($0, currentUsername: currentUsername)
            } ?? false,
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
    static let readableConversationWidth: CGFloat = 820
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
    static var fileHeight: CGFloat {
        max(54, ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
            + UIFont.preferredFont(forTextStyle: .caption2).lineHeight + 14))
    }
    static var replyPreviewHeight: CGFloat {
        max(44, ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 2 + 8))
    }
    static let replyPreviewGap: CGFloat = 7
    static let voiceHeight: CGFloat = 32
    static let stickerSize = CGSize(width: 132, height: 132)
    static var confirmButtonHeight: CGFloat {
        max(38, ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight + 16))
    }

    static func readableWidth(for containerWidth: CGFloat) -> CGFloat {
        min(containerWidth, readableConversationWidth)
    }

    static func contentInset(for containerWidth: CGFloat) -> CGFloat {
        max(horizontalInset, (containerWidth - readableWidth(for: containerWidth)) / 2 + horizontalInset)
    }

    static func messageHeight(
        for message: ChatMessage,
        containerWidth: CGFloat,
        groupedWithPrevious: Bool,
        currentUsername: String?,
        transcript: VoiceTranscript? = nil,
        transcriptExpanded: Bool = false
    ) -> CGFloat {
        let topGap = groupedWithPrevious ? sameSenderTopGap : otherSenderTopGap
        let maxBubbleWidth = max(180, readableWidth(for: containerWidth) * bubbleMaxWidthRatio)
        let contentWidth = maxBubbleWidth - bubbleHorizontalPadding * 2
        var contentHeight: CGFloat

        if message.id.hasPrefix("__ai_activity__") {
            contentHeight = 20
        } else if message.interactionPayload != nil {
            contentHeight = max(
                42,
                ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
                    + UIFont.preferredFont(forTextStyle: .caption2).lineHeight + 6))
        } else { switch message.type {
        case "image", "video":
            contentHeight = mediaContentHeight(for: message)
            if let caption = mediaCaption(for: message) {
                contentHeight += measureText(caption, font: .preferredFont(forTextStyle: .subheadline), width: contentWidth) + 14
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
                font: .preferredFont(forTextStyle: .body),
                width: contentWidth).height
            contentHeight = bodyHeight
        } }

        if let confirm = message.meta?.confirm {
            contentHeight += confirmationHeight(
                confirm,
                width: contentWidth,
                canDecide: canDecideConfirmation(confirm, currentUsername: currentUsername)) + 12
        }

        if let reply = message.replyPreview, !reply.isEmpty {
            contentHeight += replyPreviewHeight + replyPreviewGap
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
        let maxBubbleWidth = max(180, readableWidth(for: containerWidth) * bubbleMaxWidthRatio)
        let minBubbleWidth: CGFloat = 58
        let available = maxBubbleWidth - bubbleHorizontalPadding * 2
        let text = message.displayText.isEmpty ? " " : message.displayText
        if message.id.hasPrefix("__ai_activity__") {
            return 58
        }
        if message.interactionPayload != nil {
            return ceil(min(maxBubbleWidth, 196))
        }
        if message.meta?.confirm != nil { return ceil(min(maxBubbleWidth, 300)) }
        let bodyWidth = measureTextWidth(
            text,
            font: .preferredFont(forTextStyle: .body),
            maxWidth: available)
        let replyWidth = measureTextWidth(message.replyPreview ?? "", font: .preferredFont(forTextStyle: .footnote), maxWidth: available)
        let replyMinimumWidth = message.replyPreview?.isEmpty == false ? min(available, 176) : 0
        let contentWidth = min(
            maxBubbleWidth,
            max(bodyWidth, max(replyWidth, replyMinimumWidth)) + bubbleHorizontalPadding * 2)
        return ceil(max(minBubbleWidth, contentWidth))
    }

    static func mediaBubbleWidth(
        for type: String,
        containerWidth: CGFloat,
        transcriptExpanded _: Bool = false
    ) -> CGFloat {
        switch type {
        case "sticker": return stickerSize.width
        case "file": return min(readableWidth(for: containerWidth) * bubbleMaxWidthRatio, 300)
        // 转写只向下展开；气泡宽度始终与未展开的语音保持一致。
        case "voice": return min(containerWidth * bubbleMaxWidthRatio, 218)
        default: return mediaSize.width
        }
    }

    static func mediaContentHeight(for message: ChatMessage) -> CGFloat {
        guard message.type == "image" || message.type == "video",
              let url = message.mediaURL else { return mediaSize.height }

        let size: CGSize?
        if let cachedSize = ImageCache.shared.imageSize(for: url) {
            size = cachedSize
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

    static func canDecideConfirmation(
        _ confirm: ActionConfirm,
        currentUsername: String?
    ) -> Bool {
        confirm.status == "pending"
            && !confirm.requesterUsername.isEmpty
            && confirm.requesterUsername == currentUsername
    }

    static func confirmationHeight(
        _ confirm: ActionConfirm,
        width: CGFloat,
        canDecide: Bool
    ) -> CGFloat {
        let itemsHeight = ChatMarkdownRenderer.boundingSize(
            for: confirmationMarkdown(confirm),
            font: .preferredFont(forTextStyle: .subheadline),
            width: width).height
        let titleHeight = ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight)
        let statusHeight = ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight)
        return titleHeight + 7 + itemsHeight
            + (canDecide ? 10 + confirmButtonHeight : 8 + statusHeight)
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
        return voiceHeight + 10 + textHeight
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
        // 按最长逻辑行计算宽度。超过上限的文本使用标准气泡宽度自动换行，
        // 避免为了压缩短尾行而让整个多行气泡显得过短。
        let widestLine = text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(maxWidth, ceil(widestLine))
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
