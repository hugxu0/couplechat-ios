import AVFoundation
import AVKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers

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
            if let item = await loadPendingMedia(from: result.itemProvider) {
                loaded.append(item)
            }
        }
        pendingMedia.append(contentsOf: loaded)
        composer.setMediaPreviews(pendingMedia)
    }

    private func loadStickerResult(_ result: PHPickerResult?, groupId: String) async {
        guard let provider = result?.itemProvider else { return }
        let identifiers = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier, UTType.image.identifier]
        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            guard let data = await provider.loadData(typeIdentifier: identifier),
                  let image = UIImage(data: data) else { continue }
            addStickerImage(image, to: groupId)
            return
        }
    }

    private func loadPendingMedia(from provider: NSItemProvider) async -> ChatPendingMedia? {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return await loadVideo(from: provider)
        }
        return await loadImage(from: provider)
    }

    private func loadImage(from provider: NSItemProvider) async -> ChatPendingMedia? {
        let identifiers = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier, UTType.image.identifier]
        for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
            if let data = await provider.loadData(typeIdentifier: identifier),
               let image = UIImage(data: data) {
                let mime = UTType(identifier)?.preferredMIMEType ?? "image/jpeg"
                let normalized = normalizedImagePayload(data, image: image, mimeType: mime)
                let previewURL = writeTemporaryPreview(
                    data: normalized.data,
                    preferredExtension: normalized.mimeType == "image/png" ? "png" : "jpg")
                return ChatPendingMedia(
                    id: UUID().uuidString,
                    image: image,
                    data: normalized.data,
                    mimeType: normalized.mimeType,
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

    private func normalizedImagePayload(
        _ data: Data,
        image: UIImage,
        mimeType: String
    ) -> (data: Data, mimeType: String) {
        if mimeType == "image/jpeg" || mimeType == "image/png" || mimeType == "image/gif" || mimeType == "image/webp" {
            return (data, mimeType)
        }
        if let jpeg = image.jpegData(compressionQuality: 0.86) {
            return (jpeg, "image/jpeg")
        }
        return (data, mimeType)
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
