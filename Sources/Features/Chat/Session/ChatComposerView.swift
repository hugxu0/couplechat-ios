import UIKit

struct ChatPendingMedia: Identifiable {
    let id: String
    let image: UIImage
    let data: Data
    let mimeType: String
    let messageType: String
    let localPreviewURL: URL?
}

protocol ChatComposerViewDelegate: AnyObject {
    func composerDidSendText(_ text: String)
    func composerDidTapCat()
    func composerDidTapEmoji()
    func composerDidTapAttachment()
    func composerDidTapSendMedia()
    func composerDidRemoveMedia(id: String)
    func composerDidCancelReply()
    func composerRecordingBegan()
    func composerRecordingMoved(cancelled: Bool)
    func composerRecordingEnded(cancelled: Bool)
    func composerTextDidBeginEditing()
}

final class ChatComposerView: UIView, UITextViewDelegate {
    weak var delegate: ChatComposerViewDelegate?
    var heightDidChange: ((CGFloat) -> Void)?

    func setCatThinking(_ thinking: Bool) {
        if thinking {
            guard catButton.layer.animation(forKey: "cat-thinking") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.58
            pulse.toValue = 1.0
            pulse.duration = 0.72
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            catButton.layer.add(pulse, forKey: "cat-thinking")
        } else {
            catButton.layer.removeAnimation(forKey: "cat-thinking")
        }
        // 大橘是一个主题动作，不随壁纸明暗退化成系统灰。
        catButton.tintColor = accentColor
    }
    private(set) var preferredHeight: CGFloat = 58

    private let stack = UIStackView()
    private let typingLabel = UILabel()
    private let replyContainer = ChatGlassView(style: .clear, cornerRadius: 16)
    private let replyTitleLabel = UILabel()
    private let replyBodyLabel = UILabel()
    private let mediaPreviewContainer = UIStackView()
    private let mediaScrollView = UIScrollView()
    private let mediaStack = UIStackView()
    private let inputGlassContainer: UIVisualEffectView = {
        let effect = UIGlassContainerEffect()
        effect.spacing = 6
        return UIVisualEffectView(effect: effect)
    }()
    private let inputRow = UIStackView()
    private let inputCapsule = ChatGlassView(style: .clear, cornerRadius: 22)
    private let inputCapsuleRow = UIStackView()
    private let catBackgroundView = ChatGlassView(style: .clear, cornerRadius: 22, interactive: true)
    private let actionBackgroundView = ChatGlassView(style: .clear, cornerRadius: 22, interactive: true)

    private let catButton = UIButton(type: .system)
    private let emojiButton = UIButton(type: .system)
    private let attachmentButton = UIButton(type: .system)
    private let actionButton = UIButton(type: .system)
    private let replyCloseButton = UIButton(type: .system)
    private let placeholderLabel = UILabel()
    private let recordingHintLabel = UILabel()
    private let recordingContainer = UIView()
    private let recordingLabel = UILabel()
    private let recordingWaveStack = UIStackView()
    let textView = UITextView()

    var attachmentMenuSourceView: UIView { attachmentButton }

    private var previewItems: [ChatPendingMedia] = []
    private var isRecording = false
    private var recordingCancelled = false
    private var accentColor = UIColor.systemBlue
    private var usesLightContent = false
    private var textHeightConstraint: NSLayoutConstraint?
    private var mediaPreviewHeightConstraint: NSLayoutConstraint?
    private var typingVisible = false
    private var replyVisible = false
    private var mediaVisible = false
    private var waveBars: [UIView] = []


    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    func applyTheme(_ theme: ThemeManager, usesLightContent: Bool = false) {
        accentColor = theme.accent.uiColor
        self.usesLightContent = usesLightContent
        let primary = primaryTextColor
        let secondary = secondaryTextColor
        catButton.tintColor = accentColor
        attachmentButton.tintColor = secondary
        emojiButton.tintColor = secondary
        typingLabel.textColor = secondary
        placeholderLabel.textColor = secondary
        replyTitleLabel.textColor = secondary
        replyBodyLabel.textColor = primary
        replyCloseButton.tintColor = secondary
        recordingLabel.textColor = recordingCancelled ? .systemRed : secondary
        recordingHintLabel.textColor = recordingCancelled ? .systemRed : secondary
        textView.textColor = primary
        let keyboardAppearance: UIKeyboardAppearance = usesLightContent ? .dark : .light
        if textView.keyboardAppearance != keyboardAppearance {
            textView.keyboardAppearance = keyboardAppearance
            // 系统键盘正在显示时，需要主动刷新输入视图才会切换深浅外观。
            if textView.isFirstResponder {
                textView.reloadInputViews()
            }
        }
        // 普通状态完全交给 clear Liquid Glass 自适应，不再强制叠加白/黑 tint。
        // 只有发送、录音等强调状态才通过系统 tintColor 着色。
        replyContainer.clearTint()
        catBackgroundView.clearTint()
        inputCapsule.clearTint()
        updateWaveBars(level: 0.35, cancelled: recordingCancelled)
        updateActionButton()
    }

    func setTypingVisible(_ visible: Bool) {
        guard typingVisible != visible else { return }
        typingVisible = visible
        typingLabel.isHidden = !visible
        recalculateHeight()
    }

    func setReplyPreview(_ text: String?) {
        let visible = text?.isEmpty == false
        replyVisible = visible
        replyContainer.isHidden = !visible
        replyBodyLabel.text = text
        recalculateHeight()
    }

    func setMediaPreviews(_ items: [ChatPendingMedia]) {
        previewItems = items
        mediaVisible = !items.isEmpty
        mediaPreviewContainer.isHidden = items.isEmpty
        mediaPreviewHeightConstraint?.constant = 84
        mediaStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            mediaStack.addArrangedSubview(previewTile(for: item))
        }
        updateActionButton()
        recalculateHeight()
    }

    func clearText() {
        textView.text = ""
        textViewDidChange(textView)
        updatePlaceholder()
    }

    func setText(_ text: String) {
        textView.text = text
        textViewDidChange(textView)
        updatePlaceholder()
    }

    func focusTextInput() {
        textView.becomeFirstResponder()
    }

    func resignTextInput() {
        textView.resignFirstResponder()
    }

    func setStickerPanelVisible(_ visible: Bool) {
        let symbol = visible ? "keyboard" : "face.smiling"
        emojiButton.setImage(UIImage(systemName: symbol), for: .normal)
        emojiButton.accessibilityLabel = visible ? "切换到键盘" : "打开表情面板"
    }

    func setRecording(elapsed: TimeInterval, cancelled: Bool, level: CGFloat = 0.35) {
        isRecording = true
        recordingCancelled = cancelled
        recordingContainer.isHidden = false
        inputCapsuleRow.alpha = 0
        recordingLabel.text = cancelled
            ? "取消"
            : String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        recordingLabel.textColor = cancelled ? .systemRed : secondaryTextColor
        recordingHintLabel.text = cancelled ? "松开即可取消" : "松手发送 · 左滑取消"
        recordingHintLabel.textColor = cancelled ? .systemRed : secondaryTextColor
        recordingHintLabel.isHidden = false
        updateWaveBars(level: level, cancelled: cancelled)
        textView.isEditable = false
        updateActionButton()
        updatePlaceholder()
        recalculateHeight()
    }

    func clearRecording() {
        isRecording = false
        recordingCancelled = false
        recordingContainer.isHidden = true
        recordingHintLabel.isHidden = true
        inputCapsuleRow.alpha = 1
        textView.textColor = primaryTextColor
        textView.isEditable = true
        textViewDidChange(textView)
        updatePlaceholder()
        recalculateHeight()
    }

    private func build() {
        backgroundColor = .clear
        isOpaque = false

        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        typingLabel.text = "大橘正在输入…"
        typingLabel.font = .preferredFont(forTextStyle: .caption1)
        typingLabel.adjustsFontForContentSizeCategory = true
        typingLabel.textColor = .secondaryLabel
        typingLabel.isHidden = true
        typingLabel.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(typingLabel)

        buildReplyBar()
        stack.addArrangedSubview(replyContainer)

        buildMediaPreview()
        stack.addArrangedSubview(mediaPreviewContainer)

        recordingHintLabel.font = .preferredFont(forTextStyle: .footnote)
        recordingHintLabel.adjustsFontForContentSizeCategory = true
        recordingHintLabel.textAlignment = .center
        recordingHintLabel.isHidden = true
        recordingHintLabel.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(recordingHintLabel)

        buildInputRow()
        inputGlassContainer.translatesAutoresizingMaskIntoConstraints = false
        inputGlassContainer.isOpaque = false
        inputGlassContainer.backgroundColor = .clear
        inputGlassContainer.contentView.addSubview(inputRow)
        stack.addArrangedSubview(inputGlassContainer)

        NSLayoutConstraint.activate([
            inputRow.leadingAnchor.constraint(equalTo: inputGlassContainer.contentView.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: inputGlassContainer.contentView.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: inputGlassContainer.contentView.topAnchor),
            inputRow.bottomAnchor.constraint(equalTo: inputGlassContainer.contentView.bottomAnchor)
        ])

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        replyContainer.isHidden = true
        mediaPreviewContainer.isHidden = true
        updateActionButton()
        recalculateHeight()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    private func recalculateHeight() {
        let textHeight = textHeightConstraint?.constant ?? minimumTextHeight
        let inputHeight = max(CGFloat(44), textHeight + 10)
        var height: CGFloat = 12 + inputHeight
        if typingVisible { height += auxiliaryHeight(for: typingLabel) + stack.spacing }
        if replyVisible { height += replyBarHeight + stack.spacing }
        if mediaVisible { height += (mediaPreviewHeightConstraint?.constant ?? 84) + stack.spacing }
        if isRecording { height += auxiliaryHeight(for: recordingHintLabel) + stack.spacing }
        height = ceil(height)
        guard abs(preferredHeight - height) > 0.5 else { return }
        preferredHeight = height
        invalidateIntrinsicContentSize()
        heightDidChange?(height)
    }

    private func buildReplyBar() {
        replyContainer.translatesAutoresizingMaskIntoConstraints = false

        let marker = UIView()
        marker.backgroundColor = accentColor
        marker.layer.cornerRadius = 1.5
        marker.translatesAutoresizingMaskIntoConstraints = false

        replyTitleLabel.text = "引用回复"
        replyTitleLabel.font = .preferredFont(forTextStyle: .caption1)
        replyTitleLabel.adjustsFontForContentSizeCategory = true
        replyTitleLabel.textColor = .secondaryLabel

        replyBodyLabel.font = .preferredFont(forTextStyle: .footnote)
        replyBodyLabel.adjustsFontForContentSizeCategory = true
        replyBodyLabel.textColor = .label
        replyBodyLabel.lineBreakMode = .byTruncatingTail

        let labels = UIStackView(arrangedSubviews: [replyTitleLabel, replyBodyLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        replyCloseButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        replyCloseButton.tintColor = secondaryTextColor
        replyCloseButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidCancelReply() }, for: .touchUpInside)
        replyCloseButton.translatesAutoresizingMaskIntoConstraints = false

        let replyContent = replyContainer.contentView
        replyContent.addSubview(marker)
        replyContent.addSubview(labels)
        replyContent.addSubview(replyCloseButton)

        NSLayoutConstraint.activate([
            replyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            marker.leadingAnchor.constraint(equalTo: replyContent.leadingAnchor, constant: 14),
            marker.centerYAnchor.constraint(equalTo: replyContent.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 3),
            marker.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: replyCloseButton.leadingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: replyContent.centerYAnchor),
            replyCloseButton.trailingAnchor.constraint(equalTo: replyContent.trailingAnchor, constant: -10),
            replyCloseButton.centerYAnchor.constraint(equalTo: replyContent.centerYAnchor),
            replyCloseButton.widthAnchor.constraint(equalToConstant: 30),
            replyCloseButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func buildMediaPreview() {
        mediaPreviewContainer.axis = .vertical
        mediaPreviewContainer.spacing = 5
        mediaPreviewContainer.translatesAutoresizingMaskIntoConstraints = false

        mediaScrollView.showsHorizontalScrollIndicator = false
        mediaScrollView.translatesAutoresizingMaskIntoConstraints = false
        mediaStack.axis = .horizontal
        mediaStack.spacing = 8
        mediaStack.translatesAutoresizingMaskIntoConstraints = false
        mediaScrollView.addSubview(mediaStack)
        mediaPreviewContainer.addArrangedSubview(mediaScrollView)

        mediaPreviewHeightConstraint = mediaPreviewContainer.heightAnchor.constraint(equalToConstant: 84)
        mediaPreviewHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            mediaStack.leadingAnchor.constraint(equalTo: mediaScrollView.contentLayoutGuide.leadingAnchor),
            mediaStack.trailingAnchor.constraint(equalTo: mediaScrollView.contentLayoutGuide.trailingAnchor),
            mediaStack.topAnchor.constraint(equalTo: mediaScrollView.contentLayoutGuide.topAnchor),
            mediaStack.bottomAnchor.constraint(equalTo: mediaScrollView.contentLayoutGuide.bottomAnchor),
            mediaStack.heightAnchor.constraint(equalTo: mediaScrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func buildInputRow() {
        inputRow.axis = .horizontal
        inputRow.alignment = .center
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        configureCatButton()
        configureIconButton(attachmentButton, image: "paperclip")
        configureIconButton(emojiButton, image: "face.smiling")
        emojiButton.accessibilityLabel = "打开表情面板"
        configureActionButton()

        catButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidTapCat() }, for: .touchUpInside)
        attachmentButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidTapAttachment() }, for: .touchUpInside)
        emojiButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidTapEmoji() }, for: .touchUpInside)

        inputCapsule.translatesAutoresizingMaskIntoConstraints = false
        inputCapsule.update(cornerRadius: 22)

        inputCapsuleRow.axis = .horizontal
        inputCapsuleRow.alignment = .center
        inputCapsuleRow.spacing = 8
        inputCapsuleRow.translatesAutoresizingMaskIntoConstraints = false
        let inputContent = inputCapsule.contentView
        inputContent.addSubview(inputCapsuleRow)

        textView.delegate = self
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.textColor = .label
        textView.returnKeyType = .default
        textView.translatesAutoresizingMaskIntoConstraints = false
        textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: minimumTextHeight)
        textHeightConstraint?.isActive = true

        placeholderLabel.text = "输入消息"
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        inputCapsuleRow.addArrangedSubview(attachmentButton)
        inputCapsuleRow.addArrangedSubview(textView)
        inputCapsuleRow.addArrangedSubview(emojiButton)
        inputContent.addSubview(placeholderLabel)
        buildRecordingOverlay()

        inputRow.addArrangedSubview(catBackgroundView)
        inputRow.addArrangedSubview(inputCapsule)
        inputRow.addArrangedSubview(actionBackgroundView)

        NSLayoutConstraint.activate([
            inputRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            catBackgroundView.widthAnchor.constraint(equalToConstant: 44),
            catBackgroundView.heightAnchor.constraint(equalToConstant: 44),
            actionBackgroundView.widthAnchor.constraint(equalToConstant: 44),
            actionBackgroundView.heightAnchor.constraint(equalToConstant: 44),

            inputCapsule.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            inputCapsuleRow.leadingAnchor.constraint(equalTo: inputContent.leadingAnchor, constant: 12),
            inputCapsuleRow.trailingAnchor.constraint(equalTo: inputContent.trailingAnchor, constant: -10),
            inputCapsuleRow.topAnchor.constraint(equalTo: inputContent.topAnchor, constant: 3),
            inputCapsuleRow.bottomAnchor.constraint(equalTo: inputContent.bottomAnchor, constant: -3),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            attachmentButton.widthAnchor.constraint(equalToConstant: 28),
            attachmentButton.heightAnchor.constraint(equalToConstant: 36),
            emojiButton.widthAnchor.constraint(equalToConstant: 30),
            emojiButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        updatePlaceholder()
    }

    private func buildRecordingOverlay() {
        recordingContainer.isHidden = true
        recordingContainer.translatesAutoresizingMaskIntoConstraints = false
        recordingLabel.font = .preferredFont(forTextStyle: .subheadline)
        recordingLabel.adjustsFontForContentSizeCategory = true
        recordingLabel.textColor = .secondaryLabel
        recordingLabel.translatesAutoresizingMaskIntoConstraints = false

        recordingWaveStack.axis = .horizontal
        recordingWaveStack.alignment = .center
        recordingWaveStack.spacing = 3
        recordingWaveStack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<14 {
            let bar = UIView()
            bar.backgroundColor = accentColor.withAlphaComponent(0.75)
            bar.layer.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
            recordingWaveStack.addArrangedSubview(bar)
            waveBars.append(bar)
        }

        recordingContainer.addSubview(recordingWaveStack)
        recordingContainer.addSubview(recordingLabel)
        let inputContent = inputCapsule.contentView
        inputContent.addSubview(recordingContainer)

        NSLayoutConstraint.activate([
            recordingContainer.leadingAnchor.constraint(equalTo: inputContent.leadingAnchor, constant: 16),
            recordingContainer.trailingAnchor.constraint(equalTo: inputContent.trailingAnchor, constant: -16),
            recordingContainer.topAnchor.constraint(equalTo: inputContent.topAnchor),
            recordingContainer.bottomAnchor.constraint(equalTo: inputContent.bottomAnchor),
            recordingWaveStack.leadingAnchor.constraint(equalTo: recordingContainer.leadingAnchor),
            recordingWaveStack.centerYAnchor.constraint(equalTo: recordingContainer.centerYAnchor),
            recordingLabel.leadingAnchor.constraint(equalTo: recordingWaveStack.trailingAnchor, constant: 12),
            recordingLabel.trailingAnchor.constraint(lessThanOrEqualTo: recordingContainer.trailingAnchor),
            recordingLabel.centerYAnchor.constraint(equalTo: recordingContainer.centerYAnchor)
        ])
    }

    private func updateWaveBars(level: CGFloat, cancelled: Bool) {
        let normalized = min(1, max(0.08, level))
        for (index, bar) in waveBars.enumerated() {
            let phase = CGFloat((index * 37) % 11) / 10
            let height = 5 + normalized * (6 + phase * 18)
            bar.backgroundColor = (cancelled ? UIColor.systemRed : accentColor).withAlphaComponent(0.78)
            bar.constraints.first(where: { $0.firstAttribute == .height })?.constant = height
        }
        recordingWaveStack.setNeedsLayout()
    }

    private func configureCatButton() {
        catBackgroundView.update(cornerRadius: 22)
        catBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        catButton.setImage(UIImage(systemName: AccountPresentation.dajuIconName), for: .normal)
        catButton.backgroundColor = .clear
        catButton.translatesAutoresizingMaskIntoConstraints = false
        let catContent = catBackgroundView.contentView
        catContent.addSubview(catButton)
        NSLayoutConstraint.activate([
            catButton.leadingAnchor.constraint(equalTo: catContent.leadingAnchor),
            catButton.trailingAnchor.constraint(equalTo: catContent.trailingAnchor),
            catButton.topAnchor.constraint(equalTo: catContent.topAnchor),
            catButton.bottomAnchor.constraint(equalTo: catContent.bottomAnchor)
        ])
    }

    private func configureIconButton(_ button: UIButton, image: String) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.backgroundColor = .clear
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
    }

    private func configureActionButton() {
        actionBackgroundView.update(cornerRadius: 22)
        actionBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        actionButton.backgroundColor = .clear
        actionButton.layer.cornerCurve = .continuous
        actionButton.layer.cornerRadius = 22
        actionButton.clipsToBounds = true
        actionButton.contentHorizontalAlignment = .center
        actionButton.contentVerticalAlignment = .center
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        let actionContent = actionBackgroundView.contentView
        actionContent.addSubview(actionButton)
        actionButton.addAction(UIAction { [weak self] _ in self?.performActionButtonTap() }, for: .touchUpInside)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleRecordGesture(_:)))
        press.minimumPressDuration = 0.12
        actionButton.addGestureRecognizer(press)

        NSLayoutConstraint.activate([
            actionButton.leadingAnchor.constraint(equalTo: actionContent.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: actionContent.trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: actionContent.topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: actionContent.bottomAnchor)
        ])
    }

    private func updateActionButton() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMedia = !previewItems.isEmpty
        let imageName: String
        if isRecording {
            imageName = recordingCancelled ? "trash.fill" : "mic.fill"
            let color = recordingCancelled ? UIColor.systemRed : accentColor
            actionBackgroundView.setTintColor(color, alpha: 1)
            actionButton.backgroundColor = .clear
            actionButton.tintColor = .white
        } else if hasText || hasMedia {
            imageName = "arrow.up"
            actionBackgroundView.setTintColor(accentColor, alpha: 1)
            actionButton.backgroundColor = .clear
            actionButton.tintColor = .white
        } else {
            imageName = "mic"
            actionBackgroundView.clearTint()
            actionButton.backgroundColor = .clear
            actionButton.tintColor = accentColor
        }
        actionButton.setImage(UIImage(systemName: imageName), for: .normal)
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        let hasText = !(textView.text ?? "").isEmpty
        placeholderLabel.isHidden = hasText || isRecording
    }

    // 壁纸明暗与系统模式是两个维度。这里必须使用确定的前景色，
    // 不能用 .label/.secondaryLabel，否则暗色系统 + 浅壁纸会重新变成白字。
    private var primaryTextColor: UIColor { usesLightContent ? .white : .black }
    private var secondaryTextColor: UIColor { usesLightContent ? UIColor.white.withAlphaComponent(0.72) : UIColor.black.withAlphaComponent(0.58) }
    private func performActionButtonTap() {
        guard !isRecording else { return }
        if !previewItems.isEmpty {
            delegate?.composerDidTapSendMedia()
            return
        }
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            delegate?.composerDidSendText(text)
        }
    }

    @objc private func handleRecordGesture(_ gesture: UILongPressGestureRecognizer) {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty, previewItems.isEmpty else { return }

        switch gesture.state {
        case .began:
            recordingCancelled = false
            delegate?.composerRecordingBegan()
        case .changed:
            let point = gesture.location(in: actionButton)
            recordingCancelled = point.x < -70
            delegate?.composerRecordingMoved(cancelled: recordingCancelled)
        case .ended, .cancelled, .failed:
            delegate?.composerRecordingEnded(cancelled: recordingCancelled)
        default:
            break
        }
    }

    private func previewTile(for item: ChatPendingMedia) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 82).isActive = true
        container.heightAnchor.constraint(equalToConstant: 78).isActive = true

        let imageView = UIImageView(image: item.image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerCurve = .continuous
        imageView.layer.cornerRadius = 14
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .systemRed
        close.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        close.layer.cornerRadius = 12
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidRemoveMedia(id: item.id) }, for: .touchUpInside)

        container.addSubview(imageView)
        container.addSubview(close)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            close.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            close.topAnchor.constraint(equalTo: container.topAnchor),
            close.widthAnchor.constraint(equalToConstant: 24),
            close.heightAnchor.constraint(equalToConstant: 24)
        ])
        return container
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.composerTextDidBeginEditing()
    }

    func textViewDidChange(_ textView: UITextView) {
        let fitting = CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        let height = min(
            maximumTextHeight,
            max(minimumTextHeight, textView.sizeThatFits(fitting).height))
        textHeightConstraint?.constant = height
        textView.isScrollEnabled = height >= maximumTextHeight
        updateActionButton()
        recalculateHeight()
        updatePlaceholder()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
                != traitCollection.preferredContentSizeCategory else { return }
        textViewDidChange(textView)
        recalculateHeight()
    }

    private var minimumTextHeight: CGFloat {
        max(34, ceil((textView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight + 12))
    }

    private var maximumTextHeight: CGFloat {
        ceil((textView.font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight * 4 + 12)
    }

    private var replyBarHeight: CGFloat {
        max(50, ceil(replyTitleLabel.font.lineHeight + replyBodyLabel.font.lineHeight + 18))
    }

    private func auxiliaryHeight(for label: UILabel) -> CGFloat {
        max(18, ceil(label.font.lineHeight + 2))
    }
}
