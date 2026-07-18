import AVFoundation
import AVKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

extension ChatViewController: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            let purpose = photoPickerPurpose
            picker.dismiss(animated: true) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    switch purpose {
                    case .messageMedia:
                        await self.loadPickerResults(results)
                    case .sticker(let groupId):
                        await self.loadStickerResult(results.first, groupId: groupId)
                    }
                    self.photoPickerPurpose = .messageMedia
                }
            }
        }
    }

    private func loadPickerResults(_ results: [PHPickerResult]) async {
        var loaded: [ChatPendingMedia] = []
        for result in results {
            if let item = await loadPendingMedia(from: result) {
                loaded.append(item)
            }
        }
        pendingMedia.append(contentsOf: loaded)
        composer.setMediaPreviews(pendingMedia)
    }

    private func loadStickerResult(_ result: PHPickerResult?, groupId: String) async {
        guard let provider = result?.itemProvider else { return }
        guard let payload = await loadStickerPayload(from: provider) else {
            showStickerImportFailure("无法读取这张图片，请换一张后重试。")
            return
        }
        addStickerData(payload.data, mimeType: payload.mimeType, to: groupId)
    }

    private func loadStickerPayload(from provider: NSItemProvider) async -> (data: Data, mimeType: String)? {
        // 优先原生动图，再尝试 Photos 提供的全部图片表示。部分 iCloud 照片只支持
        // file representation，因此 data 与 file 两条路径都必须尝试。
        let preferredIdentifiers = [
            UTType.gif.identifier, UTType.webP.identifier,
            UTType.heic.identifier, UTType.heif.identifier,
            UTType.png.identifier, UTType.jpeg.identifier, UTType.image.identifier,
        ]
        var seen: Set<String> = []
        let identifiers = (preferredIdentifiers + provider.registeredTypeIdentifiers).filter { identifier in
            guard !seen.contains(identifier),
                  UTType(identifier)?.conforms(to: .image) == true else { return false }
            seen.insert(identifier)
            return true
        }
        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            var data = await provider.loadData(typeIdentifier: identifier)
            if data == nil {
                data = await provider.loadFileData(typeIdentifier: identifier)
            }
            guard let data, UIImage(data: data) != nil else { continue }
            let mimeType = detectedImageMIMEType(data)
                ?? UTType(identifier)?.preferredMIMEType
                ?? "image/jpeg"
            return (data, mimeType)
        }

        // 最后兼容只能按 UIImage 输出的照片；静态回退用 PNG，避免再次压缩。
        if let image = await provider.loadImageObject(),
           let data = image.pngData() {
            return (data, "image/png")
        }
        return nil
    }

    private func loadPendingMedia(from result: PHPickerResult) async -> ChatPendingMedia? {
        let provider = result.itemProvider
        let isLivePhoto = provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
        // Live Photo 当前只取静态图（配对视频尚未完整实现）；UI 会提示。
        if let image = await loadImage(from: provider, markLivePhoto: isLivePhoto) {
            if isLivePhoto {
                await MainActor.run {
                    self.presentLivePhotoStaticNoticeIfNeeded()
                }
            }
            return image
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
           let video = await loadVideo(from: provider) {
            return video
        }
        return nil
    }

    @MainActor
    private func presentLivePhotoStaticNoticeIfNeeded() {
        guard !didShowLivePhotoNoticeThisSession, presentedViewController == nil else { return }
        didShowLivePhotoNoticeThisSession = true
        let alert = UIAlertController(
            title: "实况照片",
            message: "当前版本会按静态图发送，不会上传配对视频。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func loadImage(from provider: NSItemProvider, markLivePhoto: Bool = false) async -> ChatPendingMedia? {
        let identifiers = [
            UTType.gif.identifier, UTType.webP.identifier,
            UTType.png.identifier, UTType.jpeg.identifier, UTType.image.identifier,
        ]
        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            // 优先 file 表示，减少整包 Data 峰值；失败再 loadData。
            if let fileURL = await provider.loadFile(typeIdentifier: identifier) {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0, size <= 50 * 1024 * 1024 else { continue }
                // 预览仍需解码小缩略图；发送走 fileURL。
                let previewData = try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
                guard let previewData,
                      let image = UIImage(data: previewData) else { continue }
                let mime = detectedImageMIMEType(previewData)
                    ?? UTType(identifier)?.preferredMIMEType
                    ?? "image/jpeg"
                return ChatPendingMedia(
                    id: UUID().uuidString,
                    image: image,
                    data: Data(),
                    mimeType: mime,
                    messageType: "image",
                    localPreviewURL: fileURL)
            }
            if let data = await provider.loadData(typeIdentifier: identifier),
               let image = UIImage(data: data) {
                guard data.count <= 50 * 1024 * 1024 else { continue }
                let mime = detectedImageMIMEType(data)
                    ?? UTType(identifier)?.preferredMIMEType
                    ?? "image/jpeg"
                let previewURL = writeTemporaryPreview(
                    data: data,
                    preferredExtension: imageExtension(for: mime))
                return ChatPendingMedia(
                    id: UUID().uuidString,
                    image: image,
                    data: data,
                    mimeType: mime,
                    messageType: "image",
                    localPreviewURL: previewURL)
            }
        }
        _ = markLivePhoto
        return nil
    }

    private func loadVideo(from provider: NSItemProvider) async -> ChatPendingMedia? {
        guard let url = await provider.loadFile(typeIdentifier: UTType.movie.identifier) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0, size <= 50 * 1024 * 1024 else { return nil }
        // 视频预览只生成缩略图；真正发送走 fileURL 复制，避免整段视频进内存。
        let thumb = await videoThumbnail(url: url) ?? UIImage(systemName: "play.rectangle.fill") ?? UIImage()
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/mp4"
        return ChatPendingMedia(
            id: UUID().uuidString,
            image: thumb,
            data: Data(),
            mimeType: mime,
            messageType: "video",
            localPreviewURL: url)
    }

    private func detectedImageMIMEType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        return UTType(type as String)?.preferredMIMEType
    }

    private func imageExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    private func videoThumbnail(url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }

    private func writeTemporaryPreview(data: Data, preferredExtension: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(preferredExtension)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

extension ChatViewController: UIDocumentPickerDelegate {
    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor in
            urls.forEach { sendFile($0) }
        }
    }
}

private extension NSItemProvider {
    func loadData(typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    func loadFile(typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: destination)
                continuation.resume(returning: destination)
            }
        }
    }

    func loadFileData(typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }
    }

    func loadImageObject() async -> UIImage? {
        await withCheckedContinuation { continuation in
            loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}
