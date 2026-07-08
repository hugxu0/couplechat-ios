import Combine
import UIKit

protocol ChatStickerPanelViewDelegate: AnyObject {
    func stickerPanel(_ panel: ChatStickerPanelView, didSelectEmoji emoji: String)
    func stickerPanel(_ panel: ChatStickerPanelView, didSelectSticker sticker: Sticker)
    func stickerPanel(_ panel: ChatStickerPanelView, didRequestAddStickerTo groupId: String)
    func stickerPanelDidRequestManage(_ panel: ChatStickerPanelView)
}

final class ChatStickerPanelView: UIView {
    weak var delegate: ChatStickerPanelViewDelegate?

    private enum Tab: Hashable {
        case emoji
        case favorites
        case group(String)

        var id: String {
            switch self {
            case .emoji: return "emoji"
            case .favorites: return "favorites"
            case .group(let id): return id
            }
        }
    }

    private let store: StickerStore
    private let accentColor: UIColor
    private let collectionView: UICollectionView
    private let backgroundGlass = ChatGlassView(style: .systemThinMaterial, cornerRadius: 30)
    private let tabGlass = ChatGlassView(style: .systemThinMaterial, cornerRadius: 20)
    private let tabScrollView = UIScrollView()
    private let tabStack = UIStackView()
    private var cancellables: Set<AnyCancellable> = []
    private var tabs: [Tab] = []
    private var selectedTab: Tab = .emoji
    private var items: [PanelItem] = []

    init(store: StickerStore, accentColor: UIColor) {
        self.store = store
        self.accentColor = accentColor

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(frame: .zero)
        build()
        bind()
        reloadTabs()
        reloadItems()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        backgroundColor = .clear
        isOpaque = false

        backgroundGlass.translatesAutoresizingMaskIntoConstraints = false
        backgroundGlass.update(cornerRadius: 30, tintAlpha: 0.05, borderAlpha: 0.10)
        addSubview(backgroundGlass)

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .none
        collectionView.alwaysBounceVertical = true
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseId)
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseId)
        collectionView.register(AddStickerCell.self, forCellWithReuseIdentifier: AddStickerCell.reuseId)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabGlass.translatesAutoresizingMaskIntoConstraints = false
        tabGlass.clipsToBounds = true
        tabGlass.update(cornerRadius: 20, tintAlpha: 0.04, borderAlpha: 0.10)
        tabStack.axis = .horizontal
        tabStack.spacing = 4
        tabStack.alignment = .center
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.addSubview(tabStack)
        addSubview(tabGlass)
        addSubview(tabScrollView)

        NSLayoutConstraint.activate([
            backgroundGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            backgroundGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            backgroundGlass.topAnchor.constraint(equalTo: topAnchor),
            backgroundGlass.bottomAnchor.constraint(equalTo: bottomAnchor),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            collectionView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            collectionView.bottomAnchor.constraint(equalTo: tabGlass.topAnchor, constant: -6),

            tabGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tabGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            tabGlass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            tabGlass.heightAnchor.constraint(equalToConstant: 40),

            tabScrollView.leadingAnchor.constraint(equalTo: tabGlass.leadingAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: tabGlass.trailingAnchor),
            tabScrollView.topAnchor.constraint(equalTo: tabGlass.topAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: tabGlass.bottomAnchor),

            tabStack.leadingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            tabStack.trailingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            tabStack.topAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.topAnchor, constant: 5),
            tabStack.bottomAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.bottomAnchor, constant: -5),
            tabStack.heightAnchor.constraint(equalTo: tabScrollView.frameLayoutGuide.heightAnchor, constant: -10)
        ])
    }

    private func bind() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reloadTabs()
                    self?.reloadItems()
                }
            }
            .store(in: &cancellables)
    }

    private func reloadTabs() {
        tabs = [.emoji, .favorites] + store.sortedGroups.map { .group($0.id) }
        if !tabs.contains(selectedTab) {
            selectedTab = .emoji
        }

        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            tabStack.addArrangedSubview(makeTabButton(for: tab))
        }

        let manage = UIButton(type: .system)
        manage.setImage(UIImage(systemName: "gearshape"), for: .normal)
        manage.tintColor = .secondaryLabel
        manage.backgroundColor = UIColor.white.withAlphaComponent(0.07)
        manage.layer.cornerCurve = .continuous
        manage.layer.cornerRadius = 15
        manage.widthAnchor.constraint(equalToConstant: 32).isActive = true
        manage.heightAnchor.constraint(equalToConstant: 30).isActive = true
        manage.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.stickerPanelDidRequestManage(self)
        }, for: .touchUpInside)
        tabStack.addArrangedSubview(manage)
    }

    private func makeTabButton(for tab: Tab) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9)
        config.imagePadding = 4
        config.baseBackgroundColor = tab == selectedTab ? accentColor.withAlphaComponent(0.92) : UIColor.white.withAlphaComponent(0.06)
        config.baseForegroundColor = tab == selectedTab ? .white : .secondaryLabel
        config.title = title(for: tab)
        config.image = UIImage(systemName: icon(for: tab))

        let button = UIButton(configuration: config)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.selectedTab = tab
            Haptics.selection()
            self.reloadTabs()
            self.reloadItems()
        }, for: .touchUpInside)
        return button
    }

    private func reloadItems() {
        switch selectedTab {
        case .emoji:
            items = EmojiCatalog.sections.flatMap { section in
                section.emojis.map { PanelItem.emoji($0) }
            }
        case .favorites:
            items = store.favorites.map { .sticker($0) }
        case .group(let id):
            items = store.stickers(in: id).map { .sticker($0) }
            items.append(.addSticker(groupId: id))
        }
        collectionView.reloadData()
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .emoji: return "表情"
        case .favorites: return "收藏"
        case .group(let id):
            return store.sortedGroups.first(where: { $0.id == id })?.name ?? "我的表情"
        }
    }

    private func icon(for tab: Tab) -> String {
        switch tab {
        case .emoji: return "face.smiling"
        case .favorites: return "star.fill"
        case .group: return "square.grid.2x2"
        }
    }
}

extension ChatStickerPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch items[indexPath.item] {
        case .emoji(let emoji):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseId, for: indexPath) as! EmojiCell
            cell.configure(emoji)
            return cell
        case .sticker(let sticker):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StickerCell.reuseId, for: indexPath) as! StickerCell
            cell.configure(sticker)
            return cell
        case .addSticker:
            return collectionView.dequeueReusableCell(withReuseIdentifier: AddStickerCell.reuseId, for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        switch items[indexPath.item] {
        case .emoji(let emoji):
            Haptics.light()
            delegate?.stickerPanel(self, didSelectEmoji: emoji)
        case .sticker(let sticker):
            Haptics.light()
            delegate?.stickerPanel(self, didSelectSticker: sticker)
        case .addSticker(let groupId):
            delegate?.stickerPanel(self, didRequestAddStickerTo: groupId)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .sticker(let sticker) = items[indexPath.item] else { return nil }
        return UIContextMenuConfiguration(identifier: sticker.id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(
                    title: sticker.favorite ? "取消收藏" : "收藏",
                    image: UIImage(systemName: sticker.favorite ? "star.slash" : "star")
                ) { _ in
                    self.store.toggleFavorite(sticker)
                }
            ]

            let moveActions = self.store.sortedGroups.map { group in
                UIAction(title: group.name, image: UIImage(systemName: "folder")) { _ in
                    self.store.move(sticker, to: group.id)
                }
            }
            if !moveActions.isEmpty {
                actions.append(UIMenu(title: "移动到分组", image: UIImage(systemName: "folder"), children: moveActions))
            }

            actions.append(UIAction(title: "删除表情", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.store.delete(sticker)
            })
            return UIMenu(children: actions)
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        switch items[indexPath.item] {
        case .emoji:
            return CGSize(width: 42, height: 42)
        default:
            return CGSize(width: 64, height: 64)
        }
    }
}

private enum PanelItem {
    case emoji(String)
    case sticker(Sticker)
    case addSticker(groupId: String)
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseId = "EmojiCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 30)
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    func configure(_ emoji: String) {
        label.text = emoji
    }
}

private final class StickerCell: UICollectionViewCell {
    static let reuseId = "StickerCell"
    private let imageView = UIImageView()
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        contentView.layer.cornerCurve = .continuous
        contentView.layer.cornerRadius = 16
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        imageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds.insetBy(dx: 6, dy: 6)
    }

    func configure(_ sticker: Sticker) {
        guard let url = sticker.mediaURL else { return }
        representedURL = url
        if let cached = ImageCache.shared.memoryImage(for: url) {
            imageView.image = cached
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, self.representedURL == url else { return }
                self.imageView.image = image
            }
        }
    }
}

private final class AddStickerCell: UICollectionViewCell {
    static let reuseId = "AddStickerCell"
    private let imageView = UIImageView(image: UIImage(systemName: "plus"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        contentView.layer.cornerCurve = .continuous
        contentView.layer.cornerRadius = 16
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .center
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }
}
