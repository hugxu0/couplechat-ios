import PhotosUI
import UIKit
import UniformTypeIdentifiers

extension ChatViewController {
    func showAttachmentMenu() {
        inputState = .attachmentPicking
        hidePanel(animated: true)
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "照片或视频", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "文件", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.inputState = .idle
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = composer
            popover.sourceRect = composer.bounds
        }
        present(sheet, animated: true)
    }

    func presentPhotoPicker() {
        photoPickerPurpose = .messageMedia
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 9
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func presentStickerPicker(groupId: String) {
        photoPickerPurpose = .sticker(groupId: groupId)
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func sendPendingMedia() {
        let items = pendingMedia
        guard !items.isEmpty else { return }
        let caption = composer.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingMedia = []
        composer.setMediaPreviews([])
        composer.clearText()
        stickToLatestAfterNextReload = true
        var captionConsumed = false
        for item in items {
            sendSingleMedia(item, caption: captionConsumed ? nil : caption)
            captionConsumed = captionConsumed || !caption.isEmpty
        }
        reloadTimeline(animated: true)
    }

    func sendSingleMedia(_ item: ChatPendingMedia, caption: String?) {
        store.sendMedia(
            data: item.data,
            mimeType: item.mimeType,
            preferredType: item.messageType,
            localPreviewURL: item.localPreviewURL,
            channel: channel,
            displayText: caption?.isEmpty == false ? caption : nil)
    }

    func sendFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        stickToLatestAfterNextReload = true
        store.sendMedia(
            data: data,
            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
            preferredType: "file",
            localPreviewURL: nil,
            channel: channel,
            displayText: url.lastPathComponent)
        reloadTimeline(animated: true)
    }

    func addStickerImage(_ image: UIImage, to groupId: String) {
        Task {
            guard let url = await store.uploadSticker(image) else {
                Haptics.medium()
                return
            }
            StickerStore.shared.add(url: url, groupId: groupId)
            Haptics.light()
        }
    }

    func showStickerManage() {
        let alert = UIAlertController(title: "表情管理", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "新建分组", style: .default) { [weak self] _ in
            self?.showCreateStickerGroup()
        })
        let groups = StickerStore.shared.sortedGroups.filter { $0.id != StickerStore.defaultGroupId }
        for group in groups {
            alert.addAction(UIAlertAction(title: "删除分组：\(group.name)", style: .destructive) { _ in
                StickerStore.shared.deleteGroup(group)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = panelContainer
            popover.sourceRect = panelContainer.bounds
        }
        present(alert, animated: true)
    }

    func showCreateStickerGroup() {
        let alert = UIAlertController(title: "新建分组", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "分组名（最多 8 字）" }
        alert.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            _ = StickerStore.shared.createGroup(name: alert.textFields?.first?.text ?? "")
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
