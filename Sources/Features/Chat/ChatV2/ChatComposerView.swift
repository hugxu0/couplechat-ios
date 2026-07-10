import PhotosUI
import UIKit

enum ChatMediaSendMode: Int {
    case separate
    case merged
}

struct ChatPendingMedia: Identifiable {
    let id: String
    let image: UIImage
    let data: Data
    let mimeType: String
    let messageType: String
    let localPreviewURL: URL?
    var pairedVideoData: Data? = nil
    var pairedVideoMimeType: String? = nil

    var isLivePhoto: Bool { pairedVideoData != nil }
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
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.92
            pulse.toValue = 1.12
            pulse.duration = 0.62
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            catButton.layer.add(pulse, forKey: "cat-thinking")
            catButton.tintColor = .systemPink
        } else {
            catButton.layer.removeAnimation(forKey: "cat-thinking")
            catButton.tintColor = usesLightContent ? .white : .secondaryLabel
        }
    }
    private(set) var preferredHeight: CGFloat = 58

    private let stack = UIStackView()
    private let typingLabel = UILabel()
    private let replyContainer = ChatGlassView(style: .systemThinMaterial, cornerRadius: 16)
    private let replyTitleLabel = UILabel()
    private let replyBodyLabel = UILabel()
    private let mediaPreviewContainer = UIStackView()
    private let mediaModeControl = UISegmentedControl(items: ["逐张发送", "合并"])
    private let mediaScrollView = UIScrollView()
    private let mediaStack = UIStackView()
    private let inputRow = UIStackView()
    private let inputCapsule = ChatGlassView(style: .systemThinMaterial, cornerRadius: 22)
    private let inputCapsuleRow = UIStackView()
    private let catBackgroundView = ChatGlassView(style: .systemThinMaterial, cornerRadius: 22)
    private let actionBackgroundView = ChatGlassView(style: .systemThinMaterial, cornerRadius: 22)

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

    private(set) var mediaSendMode: ChatMediaSendMode = .separate

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
        mediaModeControl.selectedSegmentTintColor = accentColor
        mediaModeControl.setTitleTextAttributes([.foregroundColor: primary], for: .normal)
        mediaModeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
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
        // 与所有内部文字、图标共用 usesLightContent：暗背景只能是偏暗玻璃 + 白字，
        // 亮背景只能是偏亮玻璃 + 黑字，避免面板和占位文案同时发白。
        replyContainer.setGlassTone(dark: usesLightContent, tintAlpha: usesLightContent ? 0.14 : 0.18, borderAlpha: usesLightContent ? 0.14 : 0.20)
        catBackgroundView.setGlassTone(dark: usesLightContent, tintAlpha: usesLightContent ? 0.14 : 0.18, borderAlpha: usesLightContent ? 0.14 : 0.20)
        inputCapsule.setGlassTone(dark: usesLightContent, tintAlpha: usesLightContent ? 0.16 : 0.20, borderAlpha: usesLightContent ? 0.14 : 0.20)
        actionBackgroundView.setGlassTone(dark: usesLightContent, tintAlpha: usesLightContent ? 0.14 : 0.18, borderAlpha: usesLightContent ? 0.14 : 0.20)
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
        let shouldShowMode = items.filter { $0.messageType == "image" }.count > 1
        if !shouldShowMode {
            mediaSendMode = .separate
            mediaModeControl.selectedSegmentIndex = ChatMediaSendMode.separate.rawValue
        }
        mediaModeControl.isHidden = !shouldShowMode
        mediaPreviewHeightConstraint?.constant = shouldShowMode ? 117 : 84
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

    func focusTextInput() {
        textView.becomeFirstResponder()
    }

    func resignTextInput() {
        textView.resignFirstResponder()
    }

    /// 当前输入胶囊在控制器坐标系内的精确位置，用于从壁纸同一位置采样明暗。
    func inputCapsuleFrame(in container: UIView) -> CGRect {
        inputCapsule.convert(inputCapsule.bounds, to: container)
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
        typingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        typingLabel.textColor = .secondaryLabel
        typingLabel.isHidden = true
        typingLabel.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(typingLabel)

        buildReplyBar()
        stack.addArrangedSubview(replyContainer)

        buildMediaPreview()
        stack.addArrangedSubview(mediaPreviewContainer)

        recordingHintLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        recordingHintLabel.textAlignment = .center
        recordingHintLabel.isHidden = true
        recordingHintLabel.setContentHuggingPriority(.required, for: .vertical)
        stack.addArrangedSubview(recordingHintLabel)

        buildInputRow()
        stack.addArrangedSubview(inputRow)

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
        let textHeight = textHeightConstraint?.constant ?? 34
        let inputHeight = max(CGFloat(44), textHeight + 10)
        var height: CGFloat = 12 + inputHeight
        if typingVisible { height += 18 + stack.spacing }
        if replyVisible { height += 50 + stack.spacing }
        if mediaVisible { height += (mediaPreviewHeightConstraint?.constant ?? 84) + stack.spacing }
        if isRecording { height += 18 + stack.spacing }
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
        replyTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        replyTitleLabel.textColor = .secondaryLabel

        replyBodyLabel.font = .systemFont(ofSize: 13)
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

        replyContainer.addSubview(marker)
        replyContainer.addSubview(labels)
        replyContainer.addSubview(replyCloseButton)

        NSLayoutConstraint.activate([
            replyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            marker.leadingAnchor.constraint(equalTo: replyContainer.leadingAnchor, constant: 14),
            marker.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 3),
            marker.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: replyCloseButton.leadingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),
            replyCloseButton.trailingAnchor.constraint(equalTo: replyContainer.trailingAnchor, constant: -10),
            replyCloseButton.centerYAnchor.constraint(equalTo: replyContainer.centerYAnchor),
            replyCloseButton.widthAnchor.constraint(equalToConstant: 30),
            replyCloseButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func buildMediaPreview() {
        mediaPreviewContainer.axis = .vertical
        mediaPreviewContainer.spacing = 5
        mediaPreviewContainer.translatesAutoresizingMaskIntoConstraints = false

        mediaModeControl.selectedSegmentIndex = ChatMediaSendMode.separate.rawValue
        mediaModeControl.accessibilityLabel = "多图发送方式"
        mediaModeControl.addTarget(self, action: #selector(mediaModeChanged), for: .valueChanged)
        mediaModeControl.translatesAutoresizingMaskIntoConstraints = false
        let modeHeight = mediaModeControl.heightAnchor.constraint(equalToConstant: 28)
        modeHeight.priority = .defaultHigh
        modeHeight.isActive = true
        mediaPreviewContainer.addArrangedSubview(mediaModeControl)

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

    @objc private func mediaModeChanged() {
        mediaSendMode = ChatMediaSendMode(rawValue: mediaModeControl.selectedSegmentIndex) ?? .separate
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func buildInputRow() {
        inputRow.axis = .horizontal
        inputRow.alignment = .center
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        configureCatButton()
        configureIconButton(attachmentButton, image: "paperclip")
        configureIconButton(emojiButton, image: "face.smiling")
        configureActionButton()

        catButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidTapCat() }, for: .touchUpInside)
        attachmentButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidTapAttachment() }, for: .touchUpInside)
        emojiButton.addAction(UIAction { [weak self] _ in self?.delegate?.composerDidTapEmoji() }, for: .touchUpInside)

        inputCapsule.translatesAutoresizingMaskIntoConstraints = false
        inputCapsule.update(cornerRadius: 22, tintAlpha: 0.22, borderAlpha: 0.22)

        inputCapsuleRow.axis = .horizontal
        inputCapsuleRow.alignment = .center
        inputCapsuleRow.spacing = 8
        inputCapsuleRow.translatesAutoresizingMaskIntoConstraints = false
        inputCapsule.addSubview(inputCapsuleRow)

        textView.delegate = self
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.textColor = .label
        textView.returnKeyType = .default
        textView.translatesAutoresizingMaskIntoConstraints = false
        textHeightConstraint = textView.heightAnchor.constraint(equalToConstant: 34)
        textHeightConstraint?.isActive = true

        placeholderLabel.text = "输入消息"
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        inputCapsuleRow.addArrangedSubview(attachmentButton)
        inputCapsuleRow.addArrangedSubview(textView)
        inputCapsuleRow.addArrangedSubview(emojiButton)
        inputCapsule.addSubview(placeholderLabel)
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
            inputCapsuleRow.leadingAnchor.constraint(equalTo: inputCapsule.leadingAnchor, constant: 12),
            inputCapsuleRow.trailingAnchor.constraint(equalTo: inputCapsule.trailingAnchor, constant: -10),
            inputCapsuleRow.topAnchor.constraint(equalTo: inputCapsule.topAnchor, constant: 3),
            inputCapsuleRow.bottomAnchor.constraint(equalTo: inputCapsule.bottomAnchor, constant: -3),
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
        recordingLabel.font = .systemFont(ofSize: 15, weight: .medium)
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
        inputCapsule.addSubview(recordingContainer)

        NSLayoutConstraint.activate([
            recordingContainer.leadingAnchor.constraint(equalTo: inputCapsule.leadingAnchor, constant: 16),
            recordingContainer.trailingAnchor.constraint(equalTo: inputCapsule.trailingAnchor, constant: -16),
            recordingContainer.topAnchor.constraint(equalTo: inputCapsule.topAnchor),
            recordingContainer.bottomAnchor.constraint(equalTo: inputCapsule.bottomAnchor),
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
        catBackgroundView.update(cornerRadius: 22, tintAlpha: 0.20, borderAlpha: 0.22)
        catBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        catButton.setImage(UIImage(systemName: AccountPresentation.dajuIconName), for: .normal)
        catButton.backgroundColor = .clear
        catButton.translatesAutoresizingMaskIntoConstraints = false
        catBackgroundView.addSubview(catButton)
        NSLayoutConstraint.activate([
            catButton.leadingAnchor.constraint(equalTo: catBackgroundView.leadingAnchor),
            catButton.trailingAnchor.constraint(equalTo: catBackgroundView.trailingAnchor),
            catButton.topAnchor.constraint(equalTo: catBackgroundView.topAnchor),
            catButton.bottomAnchor.constraint(equalTo: catBackgroundView.bottomAnchor)
        ])
    }

    private func configureIconButton(_ button: UIButton, image: String) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.backgroundColor = .clear
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
    }

    private func configureActionButton() {
        actionBackgroundView.update(cornerRadius: 22, tintAlpha: 0.20, borderAlpha: 0.22)
        actionBackgroundView.translatesAutoresizingMaskIntoConstraints = false

        actionButton.backgroundColor = .clear
        actionButton.layer.cornerCurve = .continuous
        actionButton.layer.cornerRadius = 22
        actionButton.clipsToBounds = true
        actionButton.contentHorizontalAlignment = .center
        actionButton.contentVerticalAlignment = .center
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionBackgroundView.addSubview(actionButton)
        actionButton.addAction(UIAction { [weak self] _ in self?.performActionButtonTap() }, for: .touchUpInside)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleRecordGesture(_:)))
        press.minimumPressDuration = 0.12
        actionButton.addGestureRecognizer(press)

        NSLayoutConstraint.activate([
            actionButton.leadingAnchor.constraint(equalTo: actionBackgroundView.leadingAnchor),
            actionButton.trailingAnchor.constraint(equalTo: actionBackgroundView.trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: actionBackgroundView.topAnchor),
            actionButton.bottomAnchor.constraint(equalTo: actionBackgroundView.bottomAnchor)
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
            // 原生玻璃的 tint 在 alpha 为 1 时仍可能被材质提亮；把实色放在按钮本身，
            // 保证录音/发送态的白色符号不会落在白底上而消失。
            actionButton.backgroundColor = color
            actionButton.tintColor = .white
        } else if hasText || hasMedia {
            imageName = "arrow.up"
            actionBackgroundView.setTintColor(accentColor, alpha: 1)
            actionButton.backgroundColor = accentColor
            actionButton.tintColor = .white
        } else {
            imageName = "mic"
            actionBackgroundView.setTintColor(glassTintColor, alpha: 0.20)
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
    private var glassTintColor: UIColor { usesLightContent ? .black : .white }

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
        if item.isLivePhoto {
            let badge = UIImageView(image: PHLivePhotoView.livePhotoBadgeImage(options: .overContent))
            badge.contentMode = .scaleAspectFit
            badge.isAccessibilityElement = false
            badge.translatesAutoresizingMaskIntoConstraints = false
            imageView.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 6),
                badge.bottomAnchor.constraint(equalTo: imageView.bottomAnchor, constant: -6),
                badge.widthAnchor.constraint(equalToConstant: 30),
                badge.heightAnchor.constraint(equalToConstant: 18)
            ])
        }
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
        let height = min(108, max(34, textView.sizeThatFits(fitting).height))
        textHeightConstraint?.constant = height
        textView.isScrollEnabled = height >= 108
        updateActionButton()
        recalculateHeight()
        updatePlaceholder()
    }
}
