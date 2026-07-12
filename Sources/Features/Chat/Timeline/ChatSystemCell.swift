import UIKit

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
        let size = label.systemLayoutSizeFitting(
            CGSize(width: max(0, contentView.bounds.width - 48), height: contentView.bounds.height))
        label.frame = CGRect(
            x: (contentView.bounds.width - size.width) / 2,
            y: (contentView.bounds.height - size.height) / 2,
            width: size.width,
            height: size.height)
    }

    func configure(text: String) {
        label.text = text
        setNeedsLayout()
    }
}
