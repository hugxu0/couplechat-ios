import AVFoundation
import PhotosUI
import UIKit

final class ChatNativeMessageCell: UICollectionViewCell, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    static let reuseId = "ChatNativeMessageCell"

    weak var delegate: ChatTimelineCellDelegate?

    private let avatarView = ChatAvatarView()
    private let bubbleView = UIView()
    private let replyView = UIView()
    private let replyMarker = UIView()
    private let replyLabel = UILabel()
    private let bodyLabel = UILabel()
    private let confirmDivider = UIView()
    private let confirmTitleLabel = UILabel()
    private let confirmItemsLabel = UILabel()
    private let confirmStatusLabel = UILabel()
    private let confirmCancelButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)
    private let interactionIconBackground = UIView()
    private let interactionEmojiLabel = UILabel()
    private let interactionTitleLabel = UILabel()
    private let interactionSubtitleLabel = UILabel()
    private let aiActivityStack = UIStackView()
    private var aiActivityDots: [UIView] = []
    private let mediaImageView = UIImageView()
    private let mediaIconView = UIImageView()
    private let albumScrollView = UIScrollView()
    private let albumIndicator = ChatAlbumIndicatorView()
    private let liveBadge = UIImageView(image: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))
    private let voiceWaveStack = UIStackView()
    private let transcriptButton = UIButton(type: .system)
    private let transcriptLabel = UILabel()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let highlightView = UIView()
    private let interactionFeather = CAGradientLayer()

    private var representedImageURL: URL?
    private var representedVoiceURL: URL?
    private var message: ChatMessage?
    private var mine = false
    private var grouped = false
    private var accentColor = UIColor.systemMint
    private var voicePlaying = false
    private var voiceProgress: CGFloat = 0
    private var voiceTranscript: VoiceTranscript?
    private var voiceTranscriptExpanded = false
    private var usesDarkIncomingBubble = false
    private var voiceWaveBars: [UIView] = []
    private var albumPhotos: [ChatAttachment] = []
    private var albumPairedIDs = Set<String>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear

        bubbleView.layer.cornerCurve = .continuous
        bubbleView.clipsToBounds = true
        bubbleView.layer.shadowOpacity = 0
        interactionFeather.startPoint = CGPoint(x: 0, y: 0)
        interactionFeather.endPoint = CGPoint(x: 1, y: 1)
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

        confirmTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        confirmItemsLabel.font = .systemFont(ofSize: 14)
        confirmItemsLabel.numberOfLines = 0
        confirmStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        confirmCancelButton.setTitle("取消", for: .normal)
        confirmButton.setTitle("确认", for: .normal)
        for button in [confirmCancelButton, confirmButton] {
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.layer.cornerCurve = .continuous
            button.layer.cornerRadius = 10
        }
        confirmCancelButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setConfirmationButtonsEnabled(false)
            self.delegate?.chatCellDidDecideConfirm(self, decision: "cancel")
        }, for: .touchUpInside)
        confirmButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setConfirmationButtonsEnabled(false)
            self.delegate?.chatCellDidDecideConfirm(self, decision: "confirm")
        }, for: .touchUpInside)

        interactionIconBackground.layer.cornerCurve = .continuous
        interactionIconBackground.layer.cornerRadius = 17
        interactionEmojiLabel.font = .systemFont(ofSize: 19)
        interactionEmojiLabel.textAlignment = .center
        interactionTitleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        interactionTitleLabel.numberOfLines = 1
        interactionSubtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        interactionSubtitleLabel.numberOfLines = 1
        interactionSubtitleLabel.adjustsFontSizeToFitWidth = true
        interactionSubtitleLabel.minimumScaleFactor = 0.78

        aiActivityStack.axis = .horizontal
        aiActivityStack.alignment = .center
        aiActivityStack.distribution = .equalSpacing
        aiActivityStack.spacing = 5
        for _ in 0..<3 {
            let dot = UIView()
            dot.layer.cornerCurve = .continuous
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            aiActivityStack.addArrangedSubview(dot)
            aiActivityDots.append(dot)
        }

        mediaImageView.contentMode = .scaleAspectFill
        mediaImageView.clipsToBounds = true
        mediaImageView.layer.cornerCurve = .continuous
        mediaImageView.layer.cornerRadius = 8

        mediaIconView.contentMode = .scaleAspectFit
        mediaIconView.tintColor = .secondaryLabel
        mediaIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        mediaIconView.isAccessibilityElement = false

        albumScrollView.isPagingEnabled = true
        albumScrollView.showsHorizontalScrollIndicator = false
        albumScrollView.delegate = self
        albumScrollView.clipsToBounds = true
        liveBadge.contentMode = .scaleAspectFit
        liveBadge.isAccessibilityElement = false

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

        transcriptButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        transcriptButton.titleLabel?.adjustsFontForContentSizeCategory = true
        transcriptButton.layer.cornerCurve = .continuous
        transcriptButton.layer.cornerRadius = 11
        transcriptButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)
        transcriptButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.chatCellDidTapTranscript(self)
        }, for: .touchUpInside)
        transcriptLabel.font = .preferredFont(forTextStyle: .subheadline)
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.numberOfLines = 0
        transcriptLabel.lineBreakMode = .byWordWrapping

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
        tap.delegate = self
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
        voiceTranscript = nil
        voiceTranscriptExpanded = false
        mediaImageView.stopAnimating()
        mediaImageView.image = nil
        mediaIconView.image = nil
        mediaIconView.isHidden = false
        bodyLabel.text = nil
        bodyLabel.attributedText = nil
        replyLabel.text = nil
        statusLabel.text = nil
        retryButton.isHidden = true
        bubbleView.subviews.forEach { $0.removeFromSuperview() }
        albumScrollView.subviews.forEach { $0.removeFromSuperview() }
        albumPhotos = []
        albumPairedIDs = []
        aiActivityDots.forEach { $0.layer.removeAllAnimations() }
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
        counterpartName: String,
        accentColor: UIColor,
        usesDarkIncomingBubble: Bool = false,
        voicePlaying: Bool = false,
        voiceProgress: CGFloat = 0,
        transcript: VoiceTranscript? = nil,
        transcriptExpanded: Bool = false
    ) {
        self.message = message
        self.mine = mine
        self.grouped = groupedWithPrevious
        self.accentColor = accentColor
        self.usesDarkIncomingBubble = usesDarkIncomingBubble
        self.voicePlaying = voicePlaying
        self.voiceProgress = voiceProgress
        self.voiceTranscript = transcript
        self.voiceTranscriptExpanded = transcriptExpanded

        let isAIActivity = message.id.hasPrefix("__ai_activity__")
        let avatarText = mine ? myAvatar : peerAvatar
        let avatarURL = mine ? myAvatarURL : peerAvatarURL
        avatarView.configure(text: avatarText, url: avatarURL)
        avatarView.isHidden = false

        let mediaOnly = Self.isStandaloneMedia(message)
        // Context-menu 预览可能在不同 trait 环境中重绘动态系统色，造成气泡翻色。
        // 这里在配置时固化当前外观下的颜色，让长按仅表现为系统的轻微抬起效果。
        // 接收气泡保留稳定的阅读底色，但避免在柔和壁纸上出现生硬的纯白/纯黑块。
        // 浅色使用轻微薰衣草灰，深色使用偏蓝紫的石墨色。
        let incomingBubbleColor = usesDarkIncomingBubble
            ? UIColor(red: 39.0 / 255.0, green: 38.0 / 255.0, blue: 52.0 / 255.0, alpha: 0.94)
            : UIColor(red: 244.0 / 255.0, green: 242.0 / 255.0, blue: 248.0 / 255.0, alpha: 0.94)
        let incomingTextColor = usesDarkIncomingBubble ? UIColor.white : UIColor.label.resolvedColor(with: traitCollection)
        let incomingSecondaryColor = usesDarkIncomingBubble ? UIColor.white.withAlphaComponent(0.72) : UIColor.secondaryLabel.resolvedColor(with: traitCollection)
        let isInteraction = message.interactionPayload != nil
        let interactionColor: UIColor = {
            guard let kind = message.interactionPayload?.kind else { return .systemPink }
            switch kind {
            case .miss, .flower: return UIColor(red: 0.94, green: 0.34, blue: 0.55, alpha: 1)
            case .pat: return UIColor(red: 0.95, green: 0.58, blue: 0.24, alpha: 1)
            case .poop: return UIColor(red: 0.68, green: 0.45, blue: 0.29, alpha: 1)
            case .note: return UIColor(red: 0.46, green: 0.45, blue: 0.88, alpha: 1)
            }
        }()
        bubbleView.backgroundColor = mediaOnly ? .clear : (isAIActivity
            ? accentColor.withAlphaComponent(usesDarkIncomingBubble ? 0.24 : 0.11)
            : (isInteraction
            ? (usesDarkIncomingBubble ? UIColor.black.withAlphaComponent(0.58) : UIColor.systemBackground.withAlphaComponent(0.72))
            : (mine ? accentColor : incomingBubbleColor)))
        bubbleView.layer.borderWidth = isInteraction ? 1 : 0
        bubbleView.layer.borderColor = isInteraction
            ? interactionColor.withAlphaComponent(usesDarkIncomingBubble ? 0.48 : 0.28).cgColor
            : UIColor.clear.cgColor
        bodyLabel.textColor = isInteraction
            ? (usesDarkIncomingBubble ? .white : interactionColor.withAlphaComponent(0.92))
            : (mine ? .white : incomingTextColor)
        let contentColor = bodyLabel.textColor ?? incomingTextColor
        confirmDivider.backgroundColor = contentColor.withAlphaComponent(0.16)
        confirmTitleLabel.textColor = contentColor.withAlphaComponent(0.78)
        confirmItemsLabel.textColor = contentColor
        confirmStatusLabel.textColor = contentColor.withAlphaComponent(0.72)
        confirmCancelButton.setTitleColor(contentColor.withAlphaComponent(0.76), for: .normal)
        confirmCancelButton.backgroundColor = contentColor.withAlphaComponent(0.10)
        confirmButton.setTitleColor(mine ? accentColor : .white, for: .normal)
        confirmButton.backgroundColor = mine ? UIColor.white : accentColor
        interactionTitleLabel.textColor = usesDarkIncomingBubble ? .white : UIColor.label.resolvedColor(with: traitCollection)
        interactionSubtitleLabel.textColor = usesDarkIncomingBubble
            ? UIColor.white.withAlphaComponent(0.68)
            : UIColor.secondaryLabel.resolvedColor(with: traitCollection)
        interactionIconBackground.backgroundColor = interactionColor.withAlphaComponent(usesDarkIncomingBubble ? 0.24 : 0.12)
        aiActivityDots.forEach {
            $0.backgroundColor = accentColor.withAlphaComponent(usesDarkIncomingBubble ? 0.92 : 0.68)
        }
        interactionFeather.removeFromSuperlayer()
        if isInteraction {
            interactionFeather.colors = [
                interactionColor.withAlphaComponent(usesDarkIncomingBubble ? 0.32 : 0.22).cgColor,
                interactionColor.withAlphaComponent(0.08).cgColor,
                UIColor.clear.cgColor
            ]
            interactionFeather.locations = [0, 0.56, 1]
            bubbleView.layer.insertSublayer(interactionFeather, at: 0)
        }
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

        installContent(for: message, counterpartName: counterpartName)
        setAIActivityAnimating(isAIActivity)
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
        interactionFeather.frame = bubbleView.bounds
        interactionFeather.cornerRadius = bubbleView.layer.cornerRadius
        highlightView.frame = bubbleView.frame.insetBy(dx: -5, dy: -5)
        highlightView.layer.cornerRadius = bubbleView.layer.cornerRadius + 5
        layoutBubbleContent(message)
    }

    private func installContent(for message: ChatMessage, counterpartName: String) {
        bodyLabel.font = .systemFont(ofSize: 17)
        bodyLabel.numberOfLines = 0
        bodyLabel.textAlignment = .natural
        if let reply = message.replyPreview, !reply.isEmpty {
            replyLabel.text = reply
            bubbleView.addSubview(replyView)
        }

        if message.id.hasPrefix("__ai_activity__") {
            bubbleView.addSubview(aiActivityStack)
            return
        }

        if let interaction = message.interactionPayload {
            configureInteraction(interaction, counterpartName: counterpartName)
            bubbleView.addSubview(interactionIconBackground)
            bubbleView.addSubview(interactionEmojiLabel)
            bubbleView.addSubview(interactionTitleLabel)
            bubbleView.addSubview(interactionSubtitleLabel)
            return
        }

        let photos = (message.attachments ?? [])
            .filter { $0.role == "photo" }
            .sorted { $0.order < $1.order }
        if message.type == "image", !photos.isEmpty {
            albumPhotos = photos
            if photos.count > 1 {
                bubbleView.addSubview(albumScrollView)
                bubbleView.addSubview(albumIndicator)
                configureAlbum(message)
                if ChatTimelineMetrics.mediaCaption(for: message) != nil {
                    bodyLabel.text = ChatTimelineMetrics.mediaCaption(for: message)
                    bodyLabel.font = .systemFont(ofSize: 15)
                    bubbleView.addSubview(bodyLabel)
                }
                return
            }
        }

        switch message.type {
        case "image", "video", "sticker":
            bubbleView.addSubview(mediaImageView)
            if message.type == "image", photos.count == 1,
               (message.attachments ?? []).contains(where: {
                   $0.assetId == photos[0].assetId && $0.role == "pairedVideo"
               }) {
                // 必须在图片之后加入层级，否则角标会被 mediaImageView 完全盖住。
                bubbleView.addSubview(liveBadge)
            }
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
            bubbleView.addSubview(transcriptButton)
            if voiceTranscriptExpanded,
               voiceTranscript?.status == .ready,
               voiceTranscript?.text?.isEmpty == false {
                bubbleView.addSubview(transcriptLabel)
            }
            configureAttachment(message)
            configureTranscript(voiceTranscript)
        case "file":
            bubbleView.addSubview(mediaIconView)
            bubbleView.addSubview(bodyLabel)
            configureAttachment(message)
        default:
            bodyLabel.attributedText = ChatMarkdownRenderer.attributedString(
                from: message.displayText,
                baseFont: bodyLabel.font,
                textColor: bodyLabel.textColor,
                accentColor: mine ? UIColor.white.withAlphaComponent(0.92) : accentColor)
            bubbleView.addSubview(bodyLabel)
        }
        if let confirm = message.meta?.confirm { installConfirmation(confirm) }
    }

    private func installConfirmation(_ confirm: ActionConfirm) {
        confirmItemsLabel.attributedText = ChatMarkdownRenderer.attributedString(
            from: ChatTimelineMetrics.confirmationMarkdown(confirm),
            baseFont: confirmItemsLabel.font,
            textColor: confirmItemsLabel.textColor,
            accentColor: mine ? UIColor.white.withAlphaComponent(0.92) : accentColor)
        let pending = confirm.status == "pending"
        confirmTitleLabel.text = pending ? "需要你的确认" : "操作结果"
        confirmStatusLabel.text = confirm.status == "confirmed"
            ? ((confirm.failed ?? 0) > 0 ? "部分操作未完成" : "已确认并执行")
            : (confirm.status == "cancelled" ? "已取消" : nil)
        confirmCancelButton.isHidden = !pending
        confirmButton.isHidden = !pending
        setConfirmationButtonsEnabled(pending)
        [confirmDivider, confirmTitleLabel, confirmItemsLabel, confirmStatusLabel, confirmCancelButton, confirmButton]
            .forEach { bubbleView.addSubview($0) }
    }

    private func setConfirmationButtonsEnabled(_ enabled: Bool) {
        confirmCancelButton.isEnabled = enabled
        confirmButton.isEnabled = enabled
        confirmCancelButton.alpha = enabled ? 1 : 0.5
        confirmButton.alpha = enabled ? 1 : 0.5
        guard !enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.message?.meta?.confirm?.status == "pending" else { return }
            self.setConfirmationButtonsEnabled(true)
        }
    }

    private func configureInteraction(_ payload: InteractionPayload, counterpartName: String) {
        let title: String
        let incomingDetail: String
        let outgoingDetail: String
        switch payload.kind {
        case .miss:
            interactionEmojiLabel.text = "💗"
            title = "想你了"
            incomingDetail = "\(counterpartName)给你送来一次想念"
            outgoingDetail = "送给\(counterpartName)一次想念"
        case .pat:
            interactionEmojiLabel.text = "🖐️"
            title = "拍一拍"
            incomingDetail = "\(counterpartName)轻轻拍了拍你"
            outgoingDetail = "轻轻拍了拍\(counterpartName)"
        case .flower:
            interactionEmojiLabel.text = "🌸"
            title = "送花花"
            incomingDetail = "\(counterpartName)送给你一朵花"
            outgoingDetail = "送给\(counterpartName)一朵花"
        case .poop:
            interactionEmojiLabel.text = "💩"
            title = "扔粑粑"
            incomingDetail = "\(counterpartName)朝你扔了个粑粑"
            outgoingDetail = "朝\(counterpartName)扔了个粑粑"
        case .note:
            let note = payload.text.replacingOccurrences(of: "🪧", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            interactionEmojiLabel.text = "🪧"
            title = "贴条"
            incomingDetail = note.isEmpty ? "\(counterpartName)给你贴了一张小纸条" : note
            outgoingDetail = note.isEmpty ? "给\(counterpartName)贴了一张小纸条" : note
        }
        interactionTitleLabel.text = title
        interactionSubtitleLabel.text = mine ? outgoingDetail : incomingDetail
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
        if message.type == "video" {
            Task { [weak self] in
                let image = await VideoThumbnailGenerator.image(for: url)
                await MainActor.run {
                    guard let self, self.representedImageURL == url else { return }
                    self.applyMediaImage(image)
                    self.mediaIconView.isHidden = false
                    self.setNeedsLayout()
                }
            }
            return
        }
        if let cached = ImageCache.shared.memoryImage(for: url) {
            applyMediaImage(cached)
            mediaIconView.isHidden = message.type != "video"
            setNeedsLayout()
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, self.representedImageURL == url else { return }
                self.applyMediaImage(image)
                self.mediaIconView.isHidden = message.type != "video" && image != nil
                self.setNeedsLayout()
            }
        }
    }

    private func configureAlbum(_ message: ChatMessage) {
        albumPairedIDs = Set((message.attachments ?? []).filter { $0.role == "pairedVideo" }.map(\.assetId))
        albumIndicator.configure(
            page: 1,
            total: albumPhotos.count,
            isLivePhoto: albumPhotos.first.map { albumPairedIDs.contains($0.assetId) } ?? false)
        for (index, attachment) in albumPhotos.enumerated() {
            let container = UIView()
            container.clipsToBounds = true
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.tag = 100
            container.addSubview(imageView)
            container.tag = index + 1
            albumScrollView.addSubview(container)
            guard let url = attachment.mediaURL else { continue }
            Task { [weak imageView] in
                let image = await ImageCache.shared.image(for: url)
                await MainActor.run {
                    imageView?.stopAnimating()
                    imageView?.image = image
                    if image?.images?.isEmpty == false { imageView?.startAnimating() }
                }
            }
        }
    }

    private func applyMediaImage(_ image: UIImage?) {
        mediaImageView.stopAnimating()
        mediaImageView.image = image
        if image?.images?.isEmpty == false { mediaImageView.startAnimating() }
    }

    private func configureAttachment(_ message: ChatMessage) {
        let iconName: String
        if message.type == "voice" {
            iconName = voicePlaying ? "pause.fill" : "play.fill"
        } else {
            iconName = "doc.fill"
        }
        mediaIconView.image = UIImage(systemName: iconName)
        mediaIconView.isHidden = false
        let foreground = mine ? UIColor.white : (usesDarkIncomingBubble ? .white : accentColor)
        mediaIconView.tintColor = foreground
        switch message.type {
        case "voice":
            bodyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            bodyLabel.textColor = foreground
            bodyLabel.text = "···"
            updateVoiceWaveform(color: foreground)
            loadVoiceDuration(message)
        case "file":
            let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            bodyLabel.text = text.isEmpty ? "文件" : text
        default:
            bodyLabel.text = message.displayText
        }
    }

    private func configureTranscript(_ transcript: VoiceTranscript?) {
        let foreground = mine ? UIColor.white : (usesDarkIncomingBubble ? .white : accentColor)
        let title: String
        let icon: String
        let enabled: Bool
        switch transcript?.status ?? .none {
        case .none:
            title = "转文字"
            icon = "text.bubble"
            enabled = true
        case .queued:
            title = "等待中"
            icon = "clock"
            enabled = false
        case .processing:
            title = "转写中"
            icon = "ellipsis"
            enabled = false
        case .ready:
            title = voiceTranscriptExpanded ? "收起" : "看文字"
            icon = voiceTranscriptExpanded ? "chevron.up" : "text.quote"
            enabled = true
        case .failed, .unavailable:
            title = "重试转写"
            icon = "arrow.clockwise"
            enabled = true
        }
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(
            systemName: icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        configuration.imagePadding = 4
        configuration.baseForegroundColor = foreground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 7, bottom: 4, trailing: 7)
        let buttonFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold))
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = buttonFont
            return outgoing
        }
        transcriptButton.configuration = configuration
        transcriptButton.backgroundColor = foreground.withAlphaComponent(0.12)
        transcriptButton.isEnabled = enabled
        transcriptButton.alpha = enabled ? 1 : 0.72
        transcriptButton.accessibilityLabel = transcript?.status == .failed || transcript?.status == .unavailable
            ? "语音转写失败，重试"
            : title
        transcriptLabel.text = transcript?.text
        transcriptLabel.textColor = mine ? .white : (usesDarkIncomingBubble ? .white : UIColor.label)
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

        if message.id.hasPrefix("__ai_activity__") {
            aiActivityStack.frame = CGRect(
                x: 13,
                y: (bubbleView.bounds.height - 12) / 2,
                width: max(0, bubbleView.bounds.width - 26),
                height: 12)
            return
        }

        if message.interactionPayload != nil {
            let iconSize: CGFloat = 34
            let iconX: CGFloat = 12
            let iconY = (bubbleView.bounds.height - iconSize) / 2
            interactionIconBackground.frame = CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
            interactionEmojiLabel.frame = interactionIconBackground.frame
            let textX = interactionIconBackground.frame.maxX + 10
            let textWidth = max(0, bubbleView.bounds.width - textX - 12)
            interactionTitleLabel.frame = CGRect(x: textX, y: iconY - 1, width: textWidth, height: 19)
            interactionSubtitleLabel.frame = CGRect(x: textX, y: iconY + 18, width: textWidth, height: 16)
            return
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
            let availableMediaFrame = CGRect(
                x: inset,
                y: y,
                width: bubbleView.bounds.width - inset * 2,
                height: bubbleView.bounds.height - y - inset - captionHeight
            )
            let mediaFrame = fittedMediaFrame(
                in: availableMediaFrame,
                image: mediaImageView.image,
                preservesFullImage: message.type == "image" || message.type == "video"
            )
            mediaImageView.frame = mediaFrame
            if !albumPhotos.isEmpty, albumPhotos.count > 1 {
                albumScrollView.frame = mediaFrame
                albumScrollView.contentSize = CGSize(width: mediaFrame.width * CGFloat(albumPhotos.count), height: mediaFrame.height)
                for (index, container) in albumScrollView.subviews.enumerated() {
                    container.frame = CGRect(x: CGFloat(index) * mediaFrame.width, y: 0, width: mediaFrame.width, height: mediaFrame.height)
                    container.viewWithTag(100)?.frame = container.bounds
                }
                albumIndicator.frame = CGRect(x: mediaFrame.maxX - 100, y: mediaFrame.minY + 9, width: 90, height: 26)
            } else if liveBadge.superview != nil {
                liveBadge.frame = CGRect(x: mediaFrame.minX + 9, y: mediaFrame.minY + 9, width: 32, height: 20)
            }
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
            mediaIconView.frame = CGRect(x: paddingX, y: y + 7, width: 18, height: 18)
            voiceWaveStack.frame = CGRect(x: paddingX + 27, y: y + 6, width: 44, height: 20)
            bodyLabel.frame = CGRect(x: paddingX + 77, y: y + 7, width: 32, height: 18)
            transcriptButton.frame = CGRect(
                x: paddingX + 112,
                y: y + 1,
                width: max(64, bubbleView.bounds.width - paddingX * 2 - 112),
                height: 30)
            if transcriptLabel.superview != nil {
                let labelY = y + ChatTimelineMetrics.voiceHeight + 10
                let labelWidth = bubbleView.bounds.width - paddingX * 2
                let labelHeight = ceil(transcriptLabel.sizeThatFits(
                    CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
                transcriptLabel.frame = CGRect(x: paddingX, y: labelY, width: labelWidth, height: labelHeight)
            }
        case "file":
            mediaIconView.frame = CGRect(x: paddingX, y: y + 6, width: 28, height: 28)
            bodyLabel.frame = CGRect(x: paddingX + 38, y: y, width: contentWidth - 38, height: bubbleView.bounds.height - y - paddingY)
        default:
            let confirmHeight = message.meta?.confirm.map {
                ChatTimelineMetrics.confirmationHeight($0, width: contentWidth) + 12
            } ?? 0
            bodyLabel.frame = CGRect(
                x: paddingX,
                y: y,
                width: contentWidth,
                height: max(0, bubbleView.bounds.height - y - paddingY - confirmHeight))
        }
        if let confirm = message.meta?.confirm {
            layoutConfirmation(confirm, contentWidth: contentWidth, paddingX: paddingX)
        }
    }

    private func layoutConfirmation(_ confirm: ActionConfirm, contentWidth: CGFloat, paddingX: CGFloat) {
        let height = ChatTimelineMetrics.confirmationHeight(confirm, width: contentWidth)
        let originY = bubbleView.bounds.height - ChatTimelineMetrics.bubbleVerticalPadding - height
        confirmDivider.frame = CGRect(x: paddingX, y: originY - 12, width: contentWidth, height: 1)
        confirmTitleLabel.frame = CGRect(x: paddingX, y: originY, width: contentWidth, height: 22)
        let itemsHeight = ceil((confirmItemsLabel.attributedText ?? NSAttributedString(string: "")).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil).height)
        confirmItemsLabel.frame = CGRect(x: paddingX, y: originY + 29, width: contentWidth, height: itemsHeight)
        let actionY = confirmItemsLabel.frame.maxY + (confirm.status == "pending" ? 10 : 8)
        if confirm.status == "pending" {
            let gap: CGFloat = 8
            let buttonWidth = (contentWidth - gap) / 2
            confirmCancelButton.frame = CGRect(
                x: paddingX,
                y: actionY,
                width: buttonWidth,
                height: ChatTimelineMetrics.confirmButtonHeight)
            confirmButton.frame = CGRect(
                x: paddingX + buttonWidth + gap,
                y: actionY,
                width: buttonWidth,
                height: ChatTimelineMetrics.confirmButtonHeight)
            confirmStatusLabel.frame = .zero
        } else {
            confirmStatusLabel.frame = CGRect(x: paddingX, y: actionY, width: contentWidth, height: 20)
            confirmCancelButton.frame = .zero
            confirmButton.frame = .zero
        }
    }

    private func bubbleWidth(for message: ChatMessage, maxWidth: CGFloat) -> CGFloat {
        if message.id.hasPrefix("__ai_activity__") { return 58 }
        switch message.type {
        case "image", "video", "sticker", "voice", "file":
            return ChatTimelineMetrics.mediaBubbleWidth(
                for: message.type,
                containerWidth: contentView.bounds.width,
                transcriptExpanded: message.type == "voice" && voiceTranscriptExpanded)
        default:
            return min(maxWidth, ChatTimelineMetrics.textBubbleWidth(for: message, containerWidth: contentView.bounds.width))
        }
    }

    private func fittedMediaFrame(
        in availableFrame: CGRect,
        image: UIImage?,
        preservesFullImage: Bool
    ) -> CGRect {
        guard preservesFullImage,
              let image,
              image.size.width > 0,
              image.size.height > 0 else { return availableFrame }

        let scale = min(
            availableFrame.width / image.size.width,
            availableFrame.height / image.size.height
        )
        let fittedSize = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )
        let x = mine ? availableFrame.maxX - fittedSize.width : availableFrame.minX
        return CGRect(x: x, y: availableFrame.minY, width: fittedSize.width, height: fittedSize.height)
    }

    private func cornerRadius(for message: ChatMessage) -> CGFloat {
        if message.id.hasPrefix("__ai_activity__") { return 18 }
        switch message.type {
        case "image", "video": return 8
        case "sticker": return 16
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

    private func setAIActivityAnimating(_ active: Bool) {
        for (index, dot) in aiActivityDots.enumerated() {
            dot.layer.removeAllAnimations()
            guard active else { continue }
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, -3, 0]
            bounce.keyTimes = [0, 0.45, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.38, 1, 0.38]
            fade.keyTimes = bounce.keyTimes
            let group = CAAnimationGroup()
            group.animations = [bounce, fade]
            group.duration = 0.92
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.14
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            dot.layer.add(group, forKey: "daju-typing-dot")
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
            guard let localURL = try? await VoiceMediaCache.shared.localURL(for: url) else { return }
            let asset = AVURLAsset(url: localURL)
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
        guard Self.canOpenMediaPreview(message) else { return }
        switch message.type {
        case "image", "video", "file", "voice":
            delegate?.chatCellDidTapMedia(self)
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate, view !== bubbleView {
            if view is UIControl { return false }
            candidate = view.superview
        }
        return true
    }

    static func canOpenMediaPreview(_ message: ChatMessage) -> Bool {
        !message.pending && !message.failed
    }

    var selectedMediaIdentifier: String? {
        guard albumPhotos.count > 1, albumScrollView.bounds.width > 0 else { return message?.id }
        let index = min(albumPhotos.count - 1, max(0, Int(round(albumScrollView.contentOffset.x / albumScrollView.bounds.width))))
        return albumPhotos[index].id
    }

    func mediaTransitionSourceView(for identifier: String) -> UIView? {
        if let index = albumPhotos.firstIndex(where: { $0.id == identifier }),
           let container = albumScrollView.viewWithTag(index + 1),
           let imageView = container.viewWithTag(100) {
            return imageView
        }
        guard message?.id == identifier
                || message?.attachments?.contains(where: { $0.id == identifier }) == true else { return nil }
        return mediaImageView.superview == nil ? nil : mediaImageView
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === albumScrollView, scrollView.bounds.width > 0 else { return }
        let page = min(albumPhotos.count - 1, max(0, Int(round(scrollView.contentOffset.x / scrollView.bounds.width))))
        albumIndicator.configure(
            page: page + 1,
            total: albumPhotos.count,
            isLivePhoto: albumPairedIDs.contains(albumPhotos[page].assetId))
    }

    func containsBubble(point: CGPoint) -> Bool {
        bubbleView.frame.contains(point)
    }

    func bubbleTargetedPreview(in container: UIView) -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        // 系统会在长按时用 targeted preview 临时替换原视图。明确提供当前气泡填充色，
        // 避免透明 preview 参数让文字浮在模糊背景上，看起来像气泡底色消失。
        parameters.backgroundColor = bubbleView.backgroundColor ?? .clear
        // 系统上下文菜单的默认投影偶发会在收起快照后残留，气泡本身已有描边，
        // 因此预览不再额外绘制阴影。
        parameters.shadowPath = UIBezierPath()
        // 只让系统提升气泡。头像继续留在 collection cell 中，不参与坐标系转换，
        // 这样长按不会把整格内容与头像一起抖动或造成滚动位置跳变。
        parameters.visiblePath = UIBezierPath(
            roundedRect: bubbleView.bounds,
            cornerRadius: bubbleView.layer.cornerRadius
        )
        let center = container.convert(
            CGPoint(x: bubbleView.bounds.midX, y: bubbleView.bounds.midY),
            from: bubbleView)
        let target = UIPreviewTarget(container: container, center: center)
        return UITargetedPreview(view: bubbleView, parameters: parameters, target: target)
    }
}
