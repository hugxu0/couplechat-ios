import UIKit

final class ChatAvatarView: UIView {
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
