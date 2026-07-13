import AVFoundation
import AVKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

extension ChatViewController: PHPickerViewControllerDelegate {
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            picker.dismiss(animated: true)
            switch photoPickerPurpose {
            case .messageMedia:
                await loadPickerResults(results)
            case .sticker(let groupId):
                await loadStickerResult(results.first, groupId: groupId)
            }
            photoPickerPurpose = .messageMedia
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
        // 优先请求原生动图表示；如果先询问 PNG/JPEG，Photos 可能把 GIF
        // 转成静态首帧后返回，后续即使保留原始 Data 也无法恢复动画。
        let identifiers = [
            UTType.gif.identifier, UTType.webP.identifier,
            UTType.heic.identifier, UTType.heif.identifier,
            UTType.png.identifier, UTType.jpeg.identifier, UTType.image.identifier,
        ]
        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            guard let data = await provider.loadData(typeIdentifier: identifier),
                  UIImage(data: data) != nil else { continue }
            let mimeType = detectedImageMIMEType(data)
                ?? UTType(identifier)?.preferredMIMEType
                ?? "image/jpeg"
            addStickerData(data, mimeType: mimeType, to: groupId)
            return
        }
    }

    private func loadPendingMedia(from result: PHPickerResult) async -> ChatPendingMedia? {
        let provider = result.itemProvider
        // Live Photo 只取静态图，不再上传配对视频资源。
        if let image = await loadImage(from: provider) { return image }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
           let video = await loadVideo(from: provider) {
            return video
        }
        return nil
    }

    private func loadImage(from provider: NSItemProvider) async -> ChatPendingMedia? {
        let identifiers = [
            UTType.gif.identifier, UTType.webP.identifier,
            UTType.png.identifier, UTType.jpeg.identifier, UTType.image.identifier,
        ]
        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            if let data = await provider.loadData(typeIdentifier: identifier),
               let image = UIImage(data: data) {
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
        return nil
    }

    private func loadVideo(from provider: NSItemProvider) async -> ChatPendingMedia? {
        guard let url = await provider.loadFile(typeIdentifier: UTType.movie.identifier),
              let data = try? Data(contentsOf: url) else { return nil }
        let thumb = await videoThumbnail(url: url) ?? UIImage(systemName: "play.rectangle.fill") ?? UIImage()
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/mp4"
        return ChatPendingMedia(id: UUID().uuidString, image: thumb, data: data, mimeType: mime, messageType: "video", localPreviewURL: url)
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
}
