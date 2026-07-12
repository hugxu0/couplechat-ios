import AVFoundation
import PhotosUI
import UIKit

protocol ChatTimelineCellDelegate: AnyObject {
    func chatCellDidTapMedia(_ cell: ChatNativeMessageCell)
    func chatCellDidTapRetry(_ cell: ChatNativeMessageCell)
    func chatCellDidDecideConfirm(_ cell: ChatNativeMessageCell, decision: String)
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
    private let editButton = UIButton(type: .system)
    private let stack = UIStackView()
    private var reeditAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        editButton.setTitle("重新编辑", for: .normal)
        editButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        editButton.addAction(UIAction { [weak self] _ in self?.reeditAction?() }, for: .touchUpInside)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(editButton)
        contentView.addSubview(stack)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: max(0, contentView.bounds.width - 48), height: contentView.bounds.height))
        stack.frame = CGRect(
            x: (contentView.bounds.width - size.width) / 2,
            y: (contentView.bounds.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reeditAction = nil
        editButton.isHidden = true
    }

    func configure(text: String, onReedit: (() -> Void)? = nil) {
        label.text = text
        reeditAction = onReedit
        editButton.isHidden = onReedit == nil
        setNeedsLayout()
    }
}

final class ChatNativeMessageCell: UICollectionViewCell, UIScrollViewDelegate {
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
        voiceProgress: CGFloat = 0
    ) {
        self.message = message
        self.mine = mine
        self.grouped = groupedWithPrevious
        self.accentColor = accentColor
        self.usesDarkIncomingBubble = usesDarkIncomingBubble
        self.voicePlaying = voicePlaying
        self.voiceProgress = voiceProgress

        let isAIActivity = message.id.hasPrefix("__ai_activity__")
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
            configureAttachment(message)
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
                    self.mediaImageView.image = image
                    self.mediaIconView.isHidden = false
                    self.setNeedsLayout()
                }
            }
            return
        }
        if let cached = ImageCache.shared.memoryImage(for: url) {
            mediaImageView.image = cached
            mediaIconView.isHidden = message.type != "video"
            setNeedsLayout()
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, self.representedImageURL == url else { return }
                self.mediaImageView.image = image
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
                await MainActor.run { imageView?.image = image }
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
            mediaIconView.frame = CGRect(x: paddingX, y: y + 8, width: 20, height: 20)
            voiceWaveStack.frame = CGRect(x: paddingX + 30, y: y + 8, width: 50, height: 20)
            bodyLabel.frame = CGRect(x: paddingX + 88, y: y + 9, width: 34, height: 18)
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
            return ChatTimelineMetrics.mediaBubbleWidth(for: message.type, containerWidth: contentView.bounds.width)
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
        guard Self.canOpenMediaPreview(message) else { return }
        switch message.type {
        case "image", "video", "file", "voice":
            delegate?.chatCellDidTapMedia(self)
        default:
            break
        }
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

    func bubbleTargetedPreview() -> UITargetedPreview {
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        // 系统上下文菜单的默认投影偶发会在收起快照后残留，气泡本身已有描边，
        // 因此预览不再额外绘制阴影。
        parameters.shadowPath = UIBezierPath()
        // 只让系统提升气泡。头像继续留在 collection cell 中，不参与坐标系转换，
        // 这样长按不会把整格内容与头像一起抖动或造成滚动位置跳变。
        parameters.visiblePath = UIBezierPath(
            roundedRect: bubbleView.bounds,
            cornerRadius: bubbleView.layer.cornerRadius
        )
        return UITargetedPreview(view: bubbleView, parameters: parameters)
    }
}

/// 合并图片消息的原生状态层。iOS 26 把页码和 Live Photo 标识放进同一个
/// UIGlassContainerEffect，两个胶囊会按系统规则自然融合；旧系统保持低调的深色胶囊。
private final class ChatAlbumIndicatorView: UIView {
    private let containerView: UIView
    private let pageHost: UIView
    private let liveHost: UIView
    private let stack = UIStackView()
    private let pageLabel = UILabel()
    private let liveImageView = UIImageView(
        image: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let containerEffect = UIGlassContainerEffect()
            containerEffect.spacing = 7
            containerView = UIVisualEffectView(effect: containerEffect)
            pageHost = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            liveHost = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            containerView = UIView()
            pageHost = UIView()
            liveHost = UIView()
        }
        super.init(frame: frame)

        isUserInteractionEnabled = false
        isAccessibilityElement = false
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        let containerContent = (containerView as? UIVisualEffectView)?.contentView ?? containerView
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        containerContent.addSubview(stack)

        configureHost(pageHost, fallbackColor: UIColor.black.withAlphaComponent(0.54))
        configureHost(liveHost, fallbackColor: UIColor.black.withAlphaComponent(0.42))
        stack.addArrangedSubview(liveHost)
        stack.addArrangedSubview(pageHost)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        pageLabel.textColor = .white
        pageLabel.textAlignment = .center
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        hostContent(pageHost).addSubview(pageLabel)

        liveImageView.contentMode = .scaleAspectFit
        liveImageView.translatesAutoresizingMaskIntoConstraints = false
        hostContent(liveHost).addSubview(liveImageView)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: containerContent.trailingAnchor),
            stack.topAnchor.constraint(equalTo: containerContent.topAnchor),
            stack.bottomAnchor.constraint(equalTo: containerContent.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: containerContent.leadingAnchor),
            pageHost.widthAnchor.constraint(equalToConstant: 48),
            pageHost.heightAnchor.constraint(equalToConstant: 24),
            liveHost.widthAnchor.constraint(equalToConstant: 34),
            liveHost.heightAnchor.constraint(equalToConstant: 24),
            pageLabel.leadingAnchor.constraint(equalTo: hostContent(pageHost).leadingAnchor, constant: 4),
            pageLabel.trailingAnchor.constraint(equalTo: hostContent(pageHost).trailingAnchor, constant: -4),
            pageLabel.topAnchor.constraint(equalTo: hostContent(pageHost).topAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: hostContent(pageHost).bottomAnchor),
            liveImageView.leadingAnchor.constraint(equalTo: hostContent(liveHost).leadingAnchor, constant: 3),
            liveImageView.trailingAnchor.constraint(equalTo: hostContent(liveHost).trailingAnchor, constant: -3),
            liveImageView.topAnchor.constraint(equalTo: hostContent(liveHost).topAnchor, constant: 2),
            liveImageView.bottomAnchor.constraint(equalTo: hostContent(liveHost).bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(page: Int, total: Int, isLivePhoto: Bool) {
        pageLabel.text = "\(page) / \(total)"
        liveHost.isHidden = !isLivePhoto
    }

    private func configureHost(_ view: UIView, fallbackColor: UIColor) {
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
        if #unavailable(iOS 26.0) {
            view.backgroundColor = fallbackColor
        }
    }

    private func hostContent(_ view: UIView) -> UIView {
        (view as? UIVisualEffectView)?.contentView ?? view
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
