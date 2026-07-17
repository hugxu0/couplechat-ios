import UIKit

final class ChatTimeCell: UICollectionViewCell {
    static let reuseId = "ChatTimeCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
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
