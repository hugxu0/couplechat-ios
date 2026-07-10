import AVFoundation
import UIKit

protocol ChatTimelineCellDelegate: AnyObject {
    func chatCellDidTapMedia(_ cell: ChatNativeMessageCell)
    func chatCellDidTapRetry(_ cell: ChatNativeMessageCell)
}

final class ChatTimeCell: UICollectionViewCell {
    static let reuseId = "ChatTimeCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 12, dy: 0)
    }

    func configure(text: String, usesLightContent: Bool) {
        label.text = text
        // 时间分隔符直接跟随壁纸表面状态，不使用动态系统色，
        // 这样深色自定义壁纸不会留下看不清的深灰字。
        label.textColor = usesLightContent
            ? UIColor.white.withAlphaComponent(0.72)
            : UIColor.black.withAlphaComponent(0.46)
        label.shadowColor = usesLightContent
            ? UIColor.black.withAlphaComponent(0.34)
            : UIColor.white.withAlphaComponent(0.40)
        label.shadowOffset = CGSize(width: 0, height: 1)
    }
}

final class ChatSystemCell: UICollectionViewCell {
    static let reuseId = "ChatSystemCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 24, dy: 4)
    }

    func configure(text: String) {
        label.text = text
    }
}

final class ChatNativeMessageCell: UICollectionViewCell {
    static let reuseId = "ChatNativeMessageCell"

    weak var delegate: ChatTimelineCellDelegate?

    private let avatarView = ChatAvatarView()
    private let bubbleView = UIView()
    private let replyView = UIView()
    private let replyMarker = UIView()
    private let replyLabel = UILabel()
    private let bodyLabel = UILabel()
    private let mediaImageView = UIImageView()
    private let mediaIconView = UIImageView()
    private let voiceWaveStack = UIStackView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let highlightView = UIView()

    private var representedImageURL: URL?
    private var representedVoiceURL: URL?
    private var message: ChatMessage?
    private var mine = false
    private var grouped = false
    private var accentColor = UIColor.systemMint
    private var voicePlaying = false
    private var voiceProgress: CGFloat = 0
    private var usesDarkIncomingBubble = false
    private var voiceWaveBars: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear

        bubbleView.layer.cornerCurve = .continuous
        bubbleView.clipsToBounds = true
        bubbleView.layer.shadowOpacity = 0
        contentView.addSubview(avatarView)
        contentView.addSubview(highlightView)
        contentView.addSubview(bubbleView)
        contentView.addSubview(statusLabel)
        contentView.addSubview(retryButton)

        replyView.backgroundColor = UIColor.black.withAlphaComponent(0.06)
        replyView.layer.cornerRadius = 9
        replyView.clipsToBounds = true
        replyMarker.backgroundColor = .secondaryLabel
        replyLabel.font = .systemFont(ofSize: 13)
        replyLabel.textColor = .secondaryLabel
        replyLabel.numberOfLines = 1
        replyView.addSubview(replyMarker)
        replyView.addSubview(replyLabel)

        bodyLabel.font = .systemFont(ofSize: 17)
        bodyLabel.numberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping

        mediaImageView.contentMode = .scaleAspectFit
        mediaImageView.clipsToBounds = true
        mediaImageView.layer.cornerCurve = .continuous
        mediaImageView.layer.cornerRadius = 16

        mediaIconView.contentMode = .scaleAspectFit
        mediaIconView.tintColor = .secondaryLabel

        voiceWaveStack.axis = .horizontal
        voiceWaveStack.alignment = .center
        voiceWaveStack.distribution = .equalSpacing
        voiceWaveStack.spacing = 3
        for height: CGFloat in [6, 11, 17, 10, 15, 8, 13] {
            let bar = UIView()
            bar.layer.cornerRadius = 1.25
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 2.5).isActive = true
            bar.heightAnchor.constraint(equalToConstant: height).isActive = true
            voiceWaveStack.addArrangedSubview(bar)
            voiceWaveBars.append(bar)
        }

        statusLabel.font = .systemFont(ofSize: 9, weight: .bold)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerCurve = .continuous
        statusLabel.layer.borderWidth = 1.4
        statusLabel.clipsToBounds = true

        retryButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        retryButton.tintColor = .systemRed
        retryButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.chatCellDidTapRetry(self)
        }, for: .touchUpInside)

        highlightView.backgroundColor = .clear
        highlightView.layer.cornerCurve = .continuous
        highlightView.layer.borderWidth = 0
        highlightView.isUserInteractionEnabled = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBubbleTap))
        bubbleView.addGestureRecognizer(tap)
        bubbleView.isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        message = nil
        representedImageURL = nil
        representedVoiceURL = nil
        mediaImageView.image = nil
        mediaIconView.image = nil
        bodyLabel.text = nil
        replyLabel.text = nil
        statusLabel.text = nil
        retryButton.isHidden = true
        bubbleView.subviews.forEach { $0.removeFromSuperview() }
    }

    func configure(
        message: ChatMessage,
        mine: Bool,
        groupedWithPrevious: Bool,
        read: Bool,
        highlighted: Bool,
        peerAvatar: String,
        myAvatar: String,
        peerAvatarURL: URL?,
        myAvatarURL: URL?,
        accentColor: UIColor,
        usesDarkIncomingBubble: Bool = false,
        voicePlaying: Bool = false,
        voiceProgress: CGFloat = 0
    ) {
        self.message = message
        self.mine = mine
        self.grouped = groupedWithPrevious
        self.accentColor = accentColor
        self.usesDarkIncomingBubble = usesDarkIncomingBubble
        self.voicePlaying = voicePlaying
        self.voiceProgress = voiceProgress

        let avatarText = mine ? myAvatar : peerAvatar
        let avatarURL = mine ? myAvatarURL : peerAvatarURL
        avatarView.configure(text: avatarText, url: avatarURL)
        avatarView.isHidden = false

        let mediaOnly = Self.isStandaloneMedia(message)
        // Context-menu 预览可能在不同 trait 环境中重绘动态系统色，造成气泡翻色。
        // 这里在配置时固化当前外观下的颜色，让长按仅表现为系统的轻微抬起效果。
        let incomingBubbleColor = usesDarkIncomingBubble
            ? UIColor.black.withAlphaComponent(0.92)
            : UIColor.systemBackground.resolvedColor(with: traitCollection).withAlphaComponent(0.94)
        let incomingTextColor = usesDarkIncomingBubble ? UIColor.white : UIColor.label.resolvedColor(with: traitCollection)
        let incomingSecondaryColor = usesDarkIncomingBubble ? UIColor.white.withAlphaComponent(0.72) : UIColor.secondaryLabel.resolvedColor(with: traitCollection)
        bubbleView.backgroundColor = mediaOnly ? .clear : (mine ? accentColor : incomingBubbleColor)
        bodyLabel.textColor = mine ? .white : incomingTextColor
        replyMarker.backgroundColor = mine ? UIColor.white.withAlphaComponent(0.9) : accentColor
        replyLabel.textColor = mine ? UIColor.white.withAlphaComponent(0.86) : incomingSecondaryColor

        retryButton.isHidden = !message.failed
        statusLabel.text = statusText(message: message, read: read)
        statusLabel.isHidden = !mine || message.failed
        statusLabel.textColor = read ? .white : accentColor
        statusLabel.backgroundColor = read ? accentColor.withAlphaComponent(0.92) : .clear
        statusLabel.layer.borderColor = accentColor.withAlphaComponent(0.85).cgColor

        highlightView.layer.borderWidth = highlighted ? 2 : 0
        highlightView.layer.borderColor = accentColor.withAlphaComponent(0.85).cgColor
        highlightView.backgroundColor = highlighted ? accentColor.withAlphaComponent(0.12) : .clear

        installContent(for: message)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let message else { return }

        let bounds = contentView.bounds
        let topGap = grouped ? ChatTimelineMetrics.sameSenderTopGap : ChatTimelineMetrics.otherSenderTopGap
        let avatarSize = ChatTimelineMetrics.avatarSize
        let maxBubbleWidth = bounds.width * ChatTimelineMetrics.bubbleMaxWidthRatio
        let bubbleWidth = bubbleWidth(for: message, maxWidth: maxBubbleWidth)
        let bubbleHeight = bounds.height - topGap - 2
        let avatarY = topGap + max(0, bubbleHeight - avatarSize)

        if mine {
            let avatarX = bounds.width - ChatTimelineMetrics.horizontalInset - avatarSize
            avatarView.frame = CGRect(x: avatarX, y: avatarY, width: avatarSize, height: avatarSize)
            // 统一“内容右边线”：文字、图片与贴纸都止于回执左侧。
            // 回执永远外置，头像在最右，避免媒体遮挡勾选也避免内容左右跳线。
            let statusSpace = statusLabel.isHidden
                ? 0
                : ChatTimelineMetrics.statusOutsideWidth + ChatTimelineMetrics.statusOutsideGap
            let x = avatarX - ChatTimelineMetrics.avatarGap - statusSpace - bubbleWidth
            bubbleView.frame = CGRect(x: x, y: topGap, width: bubbleWidth, height: bubbleHeight)
            statusLabel.frame = statusLabel.isHidden ? .zero : CGRect(
                x: bubbleView.frame.maxX + ChatTimelineMetrics.statusOutsideGap,
                y: bubbleView.frame.maxY - 25,
                width: 16,
                height: 16
            )
            statusLabel.layer.cornerRadius = 8
            retryButton.frame = CGRect(x: bubbleView.frame.minX - 34, y: bubbleView.frame.midY - 15, width: 30, height: 30)
        } else {
            avatarView.frame = CGRect(x: ChatTimelineMetrics.horizontalInset, y: avatarY, width: avatarSize, height: avatarSize)
            let leading = ChatTimelineMetrics.horizontalInset + avatarSize + ChatTimelineMetrics.avatarGap
            bubbleView.frame = CGRect(x: leading, y: topGap, width: bubbleWidth, height: bubbleHeight)
            statusLabel.frame = .zero
            retryButton.frame = CGRect(x: bubbleView.frame.maxX + 4, y: bubbleView.frame.midY - 15, width: 30, height: 30)
        }

        bubbleView.layer.cornerRadius = cornerRadius(for: message)
        highlightView.frame = bubbleView.frame.insetBy(dx: -5, dy: -5)
        highlightView.layer.cornerRadius = bubbleView.layer.cornerRadius + 5
        layoutBubbleContent(message)
    }

    private func installContent(for message: ChatMessage) {
        bodyLabel.font = .systemFont(ofSize: 17)
        if let reply = message.replyPreview, !reply.isEmpty {
            replyLabel.text = reply
            bubbleView.addSubview(replyView)
        }

        switch message.type {
        case "image", "video", "sticker":
            bubbleView.addSubview(mediaImageView)
            bubbleView.addSubview(mediaIconView)
            if let caption = ChatTimelineMetrics.mediaCaption(for: message) {
                bodyLabel.text = caption
                bodyLabel.font = .systemFont(ofSize: 15)
                bodyLabel.textColor = mine ? .white : (usesDarkIncomingBubble ? .white : UIColor.label.resolvedColor(with: traitCollection))
                bubbleView.addSubview(bodyLabel)
            } else {
                bodyLabel.font = .systemFont(ofSize: 17)
            }
            configureMedia(message)
        case "voice":
            bubbleView.addSubview(mediaIconView)
            bubbleView.addSubview(voiceWaveStack)
            bubbleView.addSubview(bodyLabel)
            configureAttachment(message)
        case "file":
            bubbleView.addSubview(mediaIconView)
            bubbleView.addSubview(bodyLabel)
            configureAttachment(message)
        default:
            bodyLabel.text = message.displayText
            bubbleView.addSubview(bodyLabel)
        }
    }

    private func configureMedia(_ message: ChatMessage) {
        mediaImageView.backgroundColor = .clear
        mediaIconView.image = UIImage(systemName: message.type == "video" ? "play.fill" : "photo")
        mediaIconView.tintColor = mine ? .white : .secondaryLabel
        mediaIconView.isHidden = message.type == "sticker"

        guard let url = message.mediaURL else {
            if message.pending {
                mediaIconView.image = UIImage(systemName: "arrow.up.circle")
            }
            return
        }
        representedImageURL = url
        if let cached = ImageCache.shared.memoryImage(for: url) {
            mediaImageView.image = cached
            mediaIconView.isHidden = message.type != "video"
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, self.representedImageURL == url else { return }
                self.mediaImageView.image = image
                self.mediaIconView.isHidden = message.type != "video" && image != nil
            }
        }
    }

    private func configureAttachment(_ message: ChatMessage) {
        let iconName: String
        if message.type == "voice" {
            iconName = voicePlaying ? "pause.fill" : "play.fill"
        } else {
            iconName = "doc.fill"
        }
        mediaIconView.image = UIImage(systemName: iconName)
        let foreground = mine ? UIColor.white : (usesDarkIncomingBubble ? .white : accentColor)
        mediaIconView.tintColor = foreground
        switch message.type {
        case "voice":
            bodyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            bodyLabel.textColor = foreground
            bodyLabel.text = message.pending ? "···" : "0:01"
            updateVoiceWaveform(color: foreground)
            loadVoiceDuration(message)
        case "file":
            let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            bodyLabel.text = text.isEmpty ? "文件" : text
        default:
            bodyLabel.text = message.displayText
        }
    }

    private func layoutBubbleContent(_ message: ChatMessage) {
        let paddingX = ChatTimelineMetrics.bubbleHorizontalPadding
        let paddingY = ChatTimelineMetrics.bubbleVerticalPadding
        let standaloneMedia = Self.isStandaloneMedia(message)
        var y = standaloneMedia ? 0 : paddingY
        let contentWidth = bubbleView.bounds.width - paddingX * 2

        if replyView.superview != nil {
            replyView.frame = CGRect(x: paddingX, y: y, width: contentWidth, height: 36)
            replyMarker.frame = CGRect(x: 8, y: 8, width: 3, height: 20)
            replyLabel.frame = CGRect(x: 18, y: 0, width: replyView.bounds.width - 26, height: 36)
            y += 43
        }

        switch message.type {
        case "image", "video", "sticker":
            let inset: CGFloat = 0
            let caption = ChatTimelineMetrics.mediaCaption(for: message)
            let captionHeight: CGFloat
            if let caption {
                captionHeight = ceil((caption as NSString).boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: UIFont.systemFont(ofSize: 15)],
                    context: nil
                ).height) + 14
            } else {
                captionHeight = 0
            }
            mediaImageView.frame = CGRect(
                x: inset,
                y: y,
                width: bubbleView.bounds.width - inset * 2,
                height: bubbleView.bounds.height - y - inset - captionHeight
            )
            mediaIconView.frame = CGRect(x: mediaImageView.frame.midX - 18, y: mediaImageView.frame.midY - 18, width: 36, height: 36)
            if caption != nil {
                bodyLabel.frame = CGRect(
                    x: paddingX,
                    y: mediaImageView.frame.maxY + 7,
                    width: contentWidth,
                    height: captionHeight - 7
                )
            }
        case "voice":
            mediaIconView.frame = CGRect(x: paddingX, y: y + 8, width: 20, height: 20)
            voiceWaveStack.frame = CGRect(x: paddingX + 30, y: y + 8, width: 50, height: 20)
            bodyLabel.frame = CGRect(x: paddingX + 88, y: y + 9, width: 34, height: 18)
        case "file":
            mediaIconView.frame = CGRect(x: paddingX, y: y + 6, width: 28, height: 28)
            bodyLabel.frame = CGRect(x: paddingX + 38, y: y, width: contentWidth - 38, height: bubbleView.bounds.height - y - paddingY)
        default:
            bodyLabel.frame = CGRect(x: paddingX, y: y, width: contentWidth, height: bubbleView.bounds.height - y - paddingY)
        }
    }

    private func bubbleWidth(for message: ChatMessage, maxWidth: CGFloat) -> CGFloat {
        switch message.type {
        case "image", "video", "sticker", "voice", "file":
            return ChatTimelineMetrics.mediaBubbleWidth(for: message.type, containerWidth: contentView.bounds.width)
        default:
            return min(maxWidth, ChatTimelineMetrics.textBubbleWidth(for: message, containerWidth: contentView.bounds.width))
        }
    }

    private func cornerRadius(for message: ChatMessage) -> CGFloat {
        switch message.type {
        case "image", "video", "sticker": return 16
        default: return 18
        }
    }

    private static func isStandaloneMedia(_ message: ChatMessage) -> Bool {
        switch message.type {
        case "image", "video", "sticker":
            return message.replyPreview?.isEmpty != false
        default:
            return false
        }
    }

    private func statusText(message: ChatMessage, read: Bool) -> String {
        if message.pending { return "…" }
        if message.failed { return "" }
        return "✓"
    }

    private func loadVoiceDuration(_ message: ChatMessage) {
        guard !message.pending, let url = message.mediaURL else { return }
        representedVoiceURL = url
        Task { [weak self, url] in
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            guard duration.isFinite, duration > 0 else { return }
            await MainActor.run {
                guard let self, self.representedVoiceURL == url else { return }
                self.bodyLabel.text = Self.voiceDurationText(duration)
            }
        }
    }

    private static func voiceDurationText(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func setVoicePlayback(progress: CGFloat, isPlaying: Bool) {
        guard message?.type == "voice" else { return }
        voicePlaying = isPlaying
        voiceProgress = min(1, max(0, progress))
        mediaIconView.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        updateVoiceWaveform(color: mediaIconView.tintColor)
    }

    private func updateVoiceWaveform(color: UIColor) {
        let completed = voicePlaying ? max(1, Int((voiceProgress * CGFloat(voiceWaveBars.count)).rounded(.up))) : 0
        for (index, bar) in voiceWaveBars.enumerated() {
            let alpha: CGFloat = voicePlaying && index < completed ? 1 : 0.30
            bar.backgroundColor = color.withAlphaComponent(alpha)
        }
    }

    @objc private func handleBubbleTap() {
        guard let message else { return }
        if message.failed {
            delegate?.chatCellDidTapRetry(self)
            return
        }
        switch message.type {
        case "image", "video", "file", "voice":
            delegate?.chatCellDidTapMedia(self)
        default:
            break
        }
    }

    func containsBubble(point: CGPoint) -> Bool {
        bubbleView.frame.contains(point)
    }

    func bubbleTargetedPreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        // 只让系统提升气泡。头像继续留在 collection cell 中，不参与坐标系转换，
        // 这样长按不会把整格内容与头像一起抖动或造成滚动位置跳变。
        parameters.visiblePath = UIBezierPath(
            roundedRect: bubbleView.bounds,
            cornerRadius: bubbleView.layer.cornerRadius
        )
        return UITargetedPreview(view: bubbleView, parameters: parameters)
    }
}

private final class ChatAvatarView: UIView {
    private let imageView = UIImageView()
    private let label = UILabel()
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        label.font = .systemFont(ofSize: 22)
        label.textAlignment = .center
        addSubview(imageView)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        imageView.frame = bounds
        imageView.layer.cornerRadius = bounds.width / 2
        label.frame = bounds
    }

    func configure(text: String, url: URL?) {
        let isDajuDefault = text == AccountPresentation.dajuDefaultEmoji
        label.text = isDajuDefault ? nil : text
        imageView.image = isDajuDefault ? UIImage(systemName: AccountPresentation.dajuIconName) : nil
        imageView.contentMode = isDajuDefault ? .center : .scaleAspectFill
        imageView.tintColor = .secondaryLabel
        representedURL = url
        guard let url else { return }
        if let cached = ImageCache.shared.memoryImage(for: url) {
            imageView.image = cached
            imageView.contentMode = .scaleAspectFill
            label.text = nil
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, self.representedURL == url else { return }
                self.imageView.image = image
                self.imageView.contentMode = .scaleAspectFill
                if image != nil { self.label.text = nil }
            }
        }
    }
}
