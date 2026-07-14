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
        config.preferredAssetRepresentationMode = .current
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
        let text = composer.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingMedia = []
        composer.setMediaPreviews([])
        composer.clearText()
        stickToLatestAfterNextReload = true
        for item in items {
            sendSingleMedia(item)
        }
        if !text.isEmpty {
            // 输入区里的文字是一条独立消息，不作为首张图片的说明拼进媒体气泡。
            sendText(text)
        }
        reloadTimeline(animated: false)
    }

    func sendSingleMedia(_ item: ChatPendingMedia) {
        store.sendMedia(
            data: item.data,
            mimeType: item.mimeType,
            preferredType: item.messageType,
            localPreviewURL: item.localPreviewURL,
            channel: channel,
            displayText: nil)
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
        reloadTimeline(animated: false)
    }

    func addStickerData(_ data: Data, mimeType: String, to groupId: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let url = await store.uploadSticker(data: data, mimeType: mimeType) else {
                Haptics.medium()
                showStickerImportFailure("表情上传失败，请检查网络后重试。")
                return
            }
            StickerStore.shared.add(url: url, groupId: groupId)
            Haptics.light()
        }
    }

    func showStickerImportFailure(_ message: String) {
        let presentAlert = { [weak self] in
            guard let self, presentedViewController == nil else { return }
            let alert = UIAlertController(title: "添加表情失败", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
        }
        if presentedViewController == nil {
            presentAlert()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: presentAlert)
        }
    }

}
