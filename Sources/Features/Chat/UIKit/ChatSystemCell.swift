import UIKit

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
