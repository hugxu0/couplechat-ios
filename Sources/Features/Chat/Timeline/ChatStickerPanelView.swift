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
        case all
        case group(String)

        var id: String {
            switch self {
            case .emoji: return "emoji"
            case .favorites: return "favorites"
            case .all: return "all"
            case .group(let id): return id
            }
        }
    }

    private let store: StickerStore
    private var accentColor: UIColor
    private var usesLightContent = false
    private let collectionView: UICollectionView
    private let backgroundGlass = ChatGlassView(style: .systemThinMaterial, cornerRadius: 30)
    private let tabGlass = ChatGlassView(style: .systemThinMaterial, cornerRadius: 21)
    private let tabScrollView = UIScrollView()
    private let tabStack = UIStackView()
    private var cancellables: Set<AnyCancellable> = []
    private var tabs: [Tab] = []
    private var tabButtons: [Tab: UIButton] = [:]
    private var selectedTab: Tab = .emoji
    private var items: [PanelItem] = []

    init(store: StickerStore, accentColor: UIColor) {
        self.store = store
        self.accentColor = accentColor

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 8, left: 10, bottom: 4, right: 10)
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

    func applyTheme(accentColor: UIColor, usesLightContent: Bool) {
        self.accentColor = accentColor
        self.usesLightContent = usesLightContent
        // 与键盘一致使用确定的局部 appearance；不能让系统浅色模式把深色壁纸上的
        // systemMaterial 又解析成白色。
        overrideUserInterfaceStyle = usesLightContent ? .dark : .light
        backgroundGlass.setGlassTone(dark: usesLightContent, tintAlpha: usesLightContent ? 0.30 : 0.18, borderAlpha: usesLightContent ? 0.18 : 0.20)
        tabGlass.setGlassTone(dark: usesLightContent, tintAlpha: usesLightContent ? 0.24 : 0.16, borderAlpha: usesLightContent ? 0.16 : 0.18)
        collectionView.indicatorStyle = usesLightContent ? .white : .black
        reloadTabs()
        reloadItems()
    }

    private var secondaryColor: UIColor {
        usesLightContent ? UIColor.white.withAlphaComponent(0.72) : UIColor.black.withAlphaComponent(0.58)
    }

    private var neutralFill: UIColor {
        usesLightContent ? UIColor.white.withAlphaComponent(0.09) : UIColor.black.withAlphaComponent(0.06)
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
        tabGlass.update(cornerRadius: 22, tintAlpha: 0.04, borderAlpha: 0.10)
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
            collectionView.topAnchor.constraint(equalTo: tabGlass.bottomAnchor, constant: 4),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            tabGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tabGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            tabGlass.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            tabGlass.heightAnchor.constraint(equalToConstant: 52),

            tabScrollView.leadingAnchor.constraint(equalTo: tabGlass.leadingAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: tabGlass.trailingAnchor),
            tabScrollView.topAnchor.constraint(equalTo: tabGlass.topAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: tabGlass.bottomAnchor),

            tabStack.leadingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            tabStack.trailingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            tabStack.topAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.topAnchor, constant: 4),
            tabStack.bottomAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            tabStack.heightAnchor.constraint(equalTo: tabScrollView.frameLayoutGuide.heightAnchor, constant: -8)
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
        let customGroups = store.sortedGroups
            .filter { $0.id != StickerStore.defaultGroupId }
            .map { Tab.group($0.id) }
        tabs = [.emoji, .favorites, .all] + customGroups
        if !tabs.contains(selectedTab) {
            selectedTab = .emoji
        }

        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        for tab in tabs {
            let button = makeTabButton(for: tab)
            tabButtons[tab] = button
            tabStack.addArrangedSubview(button)
        }

        let manage = UIButton(type: .system)
        manage.setImage(
            UIImage(systemName: "gearshape")?.applyingSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)),
            for: .normal)
        manage.tintColor = secondaryColor
        manage.backgroundColor = neutralFill
        manage.layer.cornerCurve = .continuous
        manage.layer.cornerRadius = 18
        manage.widthAnchor.constraint(equalToConstant: 44).isActive = true
        manage.heightAnchor.constraint(equalToConstant: 44).isActive = true
        manage.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.stickerPanelDidRequestManage(self)
        }, for: .touchUpInside)
        tabStack.addArrangedSubview(manage)
    }

    private func makeTabButton(for tab: Tab) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        let button = UIButton(configuration: config)
        button.backgroundColor = tab == selectedTab ? accentColor.withAlphaComponent(0.92) : neutralFill
        button.layer.cornerCurve = .continuous
        button.layer.cornerRadius = 18
        button.imageView?.contentMode = .scaleAspectFit
        button.imageView?.clipsToBounds = true
        button.titleLabel?.font = .systemFont(ofSize: 22)
        button.tintColor = tab == selectedTab ? .white : secondaryColor
        button.accessibilityLabel = title(for: tab)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        configureIcon(for: tab, button: button)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.selectedTab = tab
            Haptics.selection()
            self.updateTabSelection()
            self.reloadItems()
        }, for: .touchUpInside)
        return button
    }

    private func updateTabSelection() {
        for (tab, button) in tabButtons {
            let selected = tab == selectedTab
            button.backgroundColor = selected ? accentColor.withAlphaComponent(0.92) : neutralFill
            button.tintColor = selected ? .white : secondaryColor
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func configureIcon(for tab: Tab, button: UIButton) {
        if tab == .emoji {
            button.setTitle(EmojiCatalog.sections.first?.emojis.first ?? "😀", for: .normal)
            return
        }
        guard let sticker = firstSticker(for: tab), let url = sticker.mediaURL else {
            button.setImage(systemTabIcon(for: tab), for: .normal)
            return
        }
        Task { [weak button] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                button?.setImage(
                    image.map(self.fittedTabIcon) ?? self.systemTabIcon(for: tab),
                    for: .normal)
            }
        }
    }

    private func fittedTabIcon(_ image: UIImage) -> UIImage {
        let canvas = CGSize(width: 28, height: 28)
        let scale = min(canvas.width / max(1, image.size.width), canvas.height / max(1, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            image.draw(in: CGRect(origin: origin, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    private func systemTabIcon(for tab: Tab) -> UIImage? {
        UIImage(systemName: icon(for: tab))?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
    }

    private func firstSticker(for tab: Tab) -> Sticker? {
        switch tab {
        case .emoji:
            return nil
        case .favorites:
            return store.favorites.first
        case .all:
            return store.stickers.sorted { $0.addedAt > $1.addedAt }.first
        case .group(let id):
            return store.stickers(in: id).first
        }
    }

    private func reloadItems() {
        switch selectedTab {
        case .emoji:
            items = EmojiCatalog.sections.flatMap { section in
                section.emojis.map { PanelItem.emoji($0) }
            }
        case .favorites:
            items = store.favorites.map { .sticker($0) }
        case .all:
            items = store.stickers
                .sorted { $0.addedAt > $1.addedAt }
                .map { .sticker($0) }
            items.append(.addSticker(groupId: StickerStore.defaultGroupId))
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
        case .all: return "所有表情"
        case .group(let id):
            return store.sortedGroups.first(where: { $0.id == id })?.name ?? "我的表情"
        }
    }

    private func icon(for tab: Tab) -> String {
        switch tab {
        case .emoji: return "face.smiling"
        case .favorites: return "star.fill"
        case .all: return "square.grid.2x2"
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
            cell.applyAppearance(fill: neutralFill)
            return cell
        case .addSticker:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AddStickerCell.reuseId, for: indexPath) as! AddStickerCell
            cell.applyAppearance(fill: neutralFill, foreground: secondaryColor)
            return cell
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
                },
                UIAction(
                    title: "移到最前",
                    image: UIImage(systemName: "arrow.up.to.line")
                ) { _ in
                    self.store.moveToFront(sticker)
                },
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

    func applyAppearance(fill: UIColor) {
        contentView.backgroundColor = fill
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

    func applyAppearance(fill: UIColor, foreground: UIColor) {
        contentView.backgroundColor = fill
        imageView.tintColor = foreground
    }
}
