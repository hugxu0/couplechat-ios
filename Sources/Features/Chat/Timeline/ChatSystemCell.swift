import UIKit

final class ChatSystemCell: UICollectionViewCell {
    static let reuseId = "ChatSystemCell"
    private let label = UILabel()
    private let reeditButton = UIButton(type: .system)
    private var onReedit: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        contentView.addSubview(label)
        reeditButton.setTitle("重新编辑", for: .normal)
        reeditButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        reeditButton.titleLabel?.adjustsFontForContentSizeCategory = true
        reeditButton.addAction(UIAction { [weak self] _ in self?.onReedit?() }, for: .touchUpInside)
        contentView.addSubview(reeditButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let labelSize = label.systemLayoutSizeFitting(
            CGSize(width: max(0, contentView.bounds.width - 48), height: contentView.bounds.height))
        let buttonSize = reeditButton.isHidden ? .zero : reeditButton.sizeThatFits(contentView.bounds.size)
        let gap: CGFloat = reeditButton.isHidden ? 0 : 7
        let totalWidth = min(contentView.bounds.width - 32, labelSize.width + gap + buttonSize.width)
        let startX = (contentView.bounds.width - totalWidth) / 2
        label.frame = CGRect(
            x: startX,
            y: (contentView.bounds.height - labelSize.height) / 2,
            width: min(labelSize.width, totalWidth),
            height: labelSize.height)
        reeditButton.frame = CGRect(
            x: label.frame.maxX + gap,
            y: (contentView.bounds.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onReedit = nil
    }

    func configure(
        text: String,
        showsReedit: Bool,
        accentColor: UIColor,
        usesLightContent: Bool,
        onReedit: (() -> Void)?
    ) {
        label.text = text
        label.textColor = usesLightContent
            ? UIColor.white.withAlphaComponent(0.72)
            : UIColor.black.withAlphaComponent(0.46)
        label.shadowColor = usesLightContent
            ? UIColor.black.withAlphaComponent(0.34)
            : UIColor.white.withAlphaComponent(0.40)
        label.shadowOffset = CGSize(width: 0, height: 1)
        reeditButton.isHidden = !showsReedit
        reeditButton.tintColor = accentColor
        self.onReedit = onReedit
        setNeedsLayout()
    }
}
