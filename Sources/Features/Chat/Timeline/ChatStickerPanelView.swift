import Combine
import UIKit

protocol ChatStickerPanelViewDelegate: AnyObject {
    func stickerPanel(_ panel: ChatStickerPanelView, didSelectEmoji emoji: String)
    func stickerPanel(_ panel: ChatStickerPanelView, didSelectSticker sticker: Sticker)
    func stickerPanel(_ panel: ChatStickerPanelView, didRequestAddStickerTo groupId: String)
}

/// 聊天输入区里的表情面板。
///
/// 导航只表达三种事情：系统 Emoji、表情总库、自建分组。总库不是一个额外的
/// StickerStore 分组，因此无论表情被移动到哪个自建分组，都会继续出现在总库里。
final class ChatStickerPanelView: UIView {
    weak var delegate: ChatStickerPanelViewDelegate?

    private enum Tab: Hashable {
        case emoji
        case library
        case group(String)
    }

    private enum PanelItem {
        case emoji(String)
        case sticker(Sticker)
        case addSticker(groupId: String)
    }

    private let store: StickerStore
    private var accentColor: UIColor
    private var usesLightContent = false
    private let backgroundGlass = ChatGlassView(style: .systemThinMaterial, cornerRadius: 30)
    private let tabScrollView = UIScrollView()
    private let tabStack = UIStackView()
    private let collectionView: UICollectionView

    private var cancellables: Set<AnyCancellable> = []
    private var tabs: [Tab] = []
    private var tabButtons: [Tab: UIButton] = [:]
    private var selectedTab: Tab = .emoji
    private var items: [PanelItem] = []
    private var tabIconRequests: [String: URL] = [:]

    init(store: StickerStore, accentColor: UIColor) {
        self.store = store
        self.accentColor = accentColor

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 10
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(frame: .zero)
        build()
        bind()
        reloadTabs(force: true)
        reloadItems()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(accentColor: UIColor, usesLightContent: Bool) {
        self.accentColor = accentColor
        self.usesLightContent = usesLightContent
        overrideUserInterfaceStyle = usesLightContent ? .dark : .light
        backgroundGlass.setGlassTone(
            dark: usesLightContent,
            tintAlpha: usesLightContent ? 0.30 : 0.18,
            borderAlpha: usesLightContent ? 0.18 : 0.20)
        collectionView.indicatorStyle = usesLightContent ? .white : .black
        updateTabSelection()
        collectionView.reloadData()
    }

    private var secondaryColor: UIColor {
        usesLightContent ? UIColor.white.withAlphaComponent(0.66) : UIColor.black.withAlphaComponent(0.55)
    }

    private func build() {
        backgroundColor = .clear
        isOpaque = false

        backgroundGlass.translatesAutoresizingMaskIntoConstraints = false
        backgroundGlass.update(cornerRadius: 30, tintAlpha: 0.05, borderAlpha: 0.10)
        addSubview(backgroundGlass)

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.alwaysBounceHorizontal = false
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabScrollView)

        tabStack.axis = .horizontal
        tabStack.alignment = .center
        tabStack.spacing = 7
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.addSubview(tabStack)

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

        NSLayoutConstraint.activate([
            backgroundGlass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            backgroundGlass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            backgroundGlass.topAnchor.constraint(equalTo: topAnchor),
            backgroundGlass.bottomAnchor.constraint(equalTo: bottomAnchor),

            tabScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tabScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            tabScrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            tabScrollView.heightAnchor.constraint(equalToConstant: 52),

            tabStack.leadingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.trailingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.bottomAnchor),
            tabStack.heightAnchor.constraint(equalTo: tabScrollView.frameLayoutGuide.heightAnchor),

            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            collectionView.topAnchor.constraint(equalTo: tabScrollView.bottomAnchor, constant: 2),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func bind() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 早于 @Published 真正赋值，推迟到下一轮再读取。
                DispatchQueue.main.async {
                    self?.reloadTabs(force: false)
                    self?.reloadItems()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Tabs

    private func reloadTabs(force: Bool) {
        let customGroups = store.sortedGroups
            .filter { $0.id != StickerStore.defaultGroupId }
            .map { Tab.group($0.id) }
        let nextTabs: [Tab] = [.emoji, .library] + customGroups

        if !nextTabs.contains(selectedTab) {
            selectedTab = .library
        }

        // 表情增删/排序时不重建整排按钮，避免已加载的分组头像闪回占位图。
        guard force || tabs != nextTabs else {
            refreshCustomGroupIcons()
            updateTabSelection()
            return
        }

        tabs = nextTabs
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        tabButtons.removeAll()
        tabIconRequests.removeAll()

        for tab in tabs {
            let button = makeTabButton(for: tab)
            tabButtons[tab] = button
            tabStack.addArrangedSubview(button)
        }
        tabStack.addArrangedSubview(makeAddGroupButton())
        updateTabSelection()
    }

    private func makeTabButton(for tab: Tab) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.backgroundColor = .clear
        button.imageView?.contentMode = .scaleAspectFit
        button.imageView?.clipsToBounds = true
        button.accessibilityLabel = title(for: tab)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        setIcon(for: tab, on: button)

        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            selectedTab = tab
            Haptics.selection()
            updateTabSelection()
            reloadItems()
        }, for: .touchUpInside)

        if case .group(let id) = tab,
           let group = store.sortedGroups.first(where: { $0.id == id }) {
            button.menu = UIMenu(children: [
                UIAction(
                    title: "删除分组",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.confirmDelete(group: group)
                },
            ])
            button.showsMenuAsPrimaryAction = false
        }
        return button
    }

    private func makeAddGroupButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(systemName: "plus")?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        let button = UIButton(configuration: configuration)
        button.backgroundColor = .clear
        button.tintColor = secondaryColor
        button.accessibilityLabel = "添加表情分组"
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.presentCreateGroupPrompt()
        }, for: .touchUpInside)
        return button
    }

    private func updateTabSelection() {
        for (tab, button) in tabButtons {
            let selected = tab == selectedTab
            button.backgroundColor = .clear
            button.tintColor = selected ? accentColor : secondaryColor
            button.alpha = selected ? 1 : 0.78
            button.transform = selected ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }

        if let addButton = tabStack.arrangedSubviews.last as? UIButton,
           !tabButtons.values.contains(where: { $0 === addButton }) {
            addButton.tintColor = secondaryColor
        }
    }

    private func setIcon(for tab: Tab, on button: UIButton) {
        switch tab {
        case .emoji:
            // 固定图标，不借用 EmojiCatalog 的第一个内容。
            button.setImage(systemImage("face.smiling", pointSize: 23), for: .normal)
        case .library:
            button.setImage(systemImage("heart.fill", pointSize: 22), for: .normal)
        case .group(let id):
            loadGroupIcon(groupId: id, into: button)
        }
    }

    private func refreshCustomGroupIcons() {
        for (tab, button) in tabButtons {
            guard case .group(let id) = tab else { continue }
            loadGroupIcon(groupId: id, into: button)
        }
    }

    private func loadGroupIcon(groupId: String, into button: UIButton) {
        guard let sticker = store.stickers(in: groupId).first,
              let url = sticker.mediaURL else {
            tabIconRequests[groupId] = nil
            button.setImage(systemImage("photo", pointSize: 21), for: .normal)
            return
        }

        tabIconRequests[groupId] = url
        if let cached = ImageCache.shared.memoryImage(for: url) {
            button.setImage(fittedTabIcon(cached), for: .normal)
            return
        }

        // 已有头像保持到新头像准备好，不在切换分组时闪占位图。
        if button.image(for: .normal) == nil {
            button.setImage(systemImage("photo", pointSize: 21), for: .normal)
        }
        Task { [weak self, weak button] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self,
                      let button,
                      self.tabIconRequests[groupId] == url,
                      let image else { return }
                button.setImage(self.fittedTabIcon(image), for: .normal)
            }
        }
    }

    private func systemImage(_ name: String, pointSize: CGFloat) -> UIImage? {
        UIImage(systemName: name)?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium))
    }

    private func fittedTabIcon(_ image: UIImage) -> UIImage {
        let canvas = CGSize(width: 30, height: 30)
        let scale = min(canvas.width / max(1, image.size.width), canvas.height / max(1, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2)
        return UIGraphicsImageRenderer(size: canvas).image { _ in
            image.draw(in: CGRect(origin: origin, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .emoji:
            return "默认表情"
        case .library:
            return "全部表情"
        case .group(let id):
            return store.sortedGroups.first(where: { $0.id == id })?.name ?? "表情分组"
        }
    }

    // MARK: - Items

    private func reloadItems() {
        switch selectedTab {
        case .emoji:
            items = EmojiCatalog.sections.flatMap { section in
                section.emojis.map(PanelItem.emoji)
            }
        case .library:
            items = [.addSticker(groupId: StickerStore.defaultGroupId)]
            items += store.stickers
                .sorted { $0.addedAt > $1.addedAt }
                .map(PanelItem.sticker)
        case .group(let id):
            items = [.addSticker(groupId: id)]
            items += store.stickers(in: id).map(PanelItem.sticker)
        }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
    }

    private func contextMenu(for sticker: Sticker) -> UIMenu {
        var actions: [UIMenuElement] = [
            UIAction(title: "移到最前", image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in
                self?.store.moveToFront(sticker)
            },
        ]

        let groups = store.sortedGroups.filter { $0.id != StickerStore.defaultGroupId }
        if !groups.isEmpty {
            let moveActions = groups.map { group in
                UIAction(
                    title: group.name,
                    image: sticker.groupId == group.id
                        ? UIImage(systemName: "checkmark")
                        : UIImage(systemName: "folder")
                ) { [weak self] _ in
                    self?.store.move(sticker, to: group.id)
                }
            }
            actions.append(UIMenu(
                title: "移到分组",
                image: UIImage(systemName: "folder"),
                children: moveActions))
        }

        actions.append(UIAction(
            title: "删除表情",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.store.delete(sticker)
        })
        return UIMenu(children: actions)
    }

    // MARK: - Group prompts

    private func presentCreateGroupPrompt() {
        guard let presenter = nearestViewController else { return }
        let alert = UIAlertController(title: "添加分组", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "分组名（最多 8 字）"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let group = self.store.createGroup(name: alert?.textFields?.first?.text ?? "")
            self.selectedTab = .group(group.id)
            self.reloadTabs(force: true)
            self.reloadItems()
            self.scrollSelectedTabIntoView()
        })
        presenter.present(alert, animated: true)
    }

    private func confirmDelete(group: StickerGroup) {
        guard let presenter = nearestViewController else {
            store.deleteGroup(group)
            return
        }
        let alert = UIAlertController(
            title: "删除“\(group.name)”分组？",
            message: "分组内的表情仍会保留在全部表情中。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.store.deleteGroup(group)
        })
        presenter.present(alert, animated: true)
    }

    private func scrollSelectedTabIntoView() {
        guard let button = tabButtons[selectedTab] else { return }
        let rect = button.convert(button.bounds, to: tabScrollView)
        tabScrollView.scrollRectToVisible(rect.insetBy(dx: -8, dy: 0), animated: true)
    }

    private var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

extension ChatStickerPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        selectedTab == .emoji
            ? UIEdgeInsets(top: 8, left: 10, bottom: 4, right: 10)
            : UIEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
        selectedTab == .emoji ? 6 : 10
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
        selectedTab == .emoji ? 6 : 8
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        switch items[indexPath.item] {
        case .emoji(let emoji):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: EmojiCell.reuseId,
                for: indexPath) as! EmojiCell
            cell.configure(emoji)
            return cell
        case .sticker(let sticker):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: StickerCell.reuseId,
                for: indexPath) as! StickerCell
            cell.configure(sticker)
            return cell
        case .addSticker:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: AddStickerCell.reuseId,
                for: indexPath) as! AddStickerCell
            cell.applyAppearance(foreground: secondaryColor)
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

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .sticker(let sticker) = items[indexPath.item] else { return nil }
        return UIContextMenuConfiguration(identifier: sticker.id as NSString, previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: sticker)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else {
            return CGSize(width: 72, height: 72)
        }
        if case .emoji = items[indexPath.item] {
            // 系统小表情恢复紧凑网格，不与图片表情共用四列大单元格。
            return CGSize(width: 42, height: 42)
        }
        // 图片表情保持四列；iPad 上单元格会变宽，但内容限制为 96pt。
        let usableWidth = collectionView.bounds.width
            - layout.sectionInset.left
            - layout.sectionInset.right
            - layout.minimumInteritemSpacing * 3
        let side = max(54, floor(usableWidth / 4))
        return CGSize(width: side, height: min(side, 104))
    }
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseId = "EmojiCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
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
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = false
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        imageView.stopAnimating()
        imageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(96, min(contentView.bounds.width, contentView.bounds.height) - 6)
        imageView.frame = CGRect(
            x: (contentView.bounds.width - side) / 2,
            y: (contentView.bounds.height - side) / 2,
            width: side,
            height: side)
    }

    func configure(_ sticker: Sticker) {
        guard let url = sticker.mediaURL else {
            representedURL = nil
            imageView.image = nil
            return
        }
        representedURL = url
        if let cached = ImageCache.shared.memoryImage(for: url) {
            applyImage(cached)
            return
        }
        Task { [weak self] in
            let image = await ImageCache.shared.image(for: url)
            await MainActor.run {
                guard let self, representedURL == url else { return }
                applyImage(image)
            }
        }
    }

    private func applyImage(_ image: UIImage?) {
        imageView.stopAnimating()
        imageView.image = image
        if image?.images?.isEmpty == false { imageView.startAnimating() }
    }
}

private final class AddStickerCell: UICollectionViewCell {
    static let reuseId = "AddStickerCell"
    private let imageView = UIImageView(image: UIImage(systemName: "plus"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        imageView.contentMode = .center
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 23, weight: .medium)
        contentView.addSubview(imageView)
        accessibilityLabel = "添加表情"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }

    func applyAppearance(foreground: UIColor) {
        imageView.tintColor = foreground
    }
}
