import AVFoundation
import AVKit
import PhotosUI
import Photos
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
            if let item = await loadPendingMedia(from: result) {
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

    private func loadPendingMedia(from result: PHPickerResult) async -> ChatPendingMedia? {
        let provider = result.itemProvider
        // Live Photo 的 provider 通常也声明自己可加载 movie。必须先识别 Live Photo，
        // 否则会把配对视频误当成普通视频，甚至因为 movie representation 不可用而整项丢失。
        if let live = await loadLivePhoto(from: result) {
            return live
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
           let video = await loadVideo(from: provider) {
            return video
        }
        return await loadImage(from: provider)
    }

    private func loadLivePhoto(from result: PHPickerResult) async -> ChatPendingMedia? {
        let provider = result.itemProvider
        if provider.canLoadObject(ofClass: PHLivePhoto.self),
           let livePhoto = await provider.loadLivePhoto(),
           let pending = await makePendingLivePhoto(
               resources: PHAssetResource.assetResources(for: livePhoto)) {
            return pending
        }

        // 少数旧系统/共享相册来源无法直接交付 PHLivePhoto。仅在用户早已授予权限时
        // 才用 assetIdentifier 回退；PHPicker 本身不需要整库权限，因此这里绝不主动弹授权。
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited,
              let assetIdentifier = result.assetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject,
              asset.mediaSubtypes.contains(.photoLive) else { return nil }
        return await makePendingLivePhoto(resources: PHAssetResource.assetResources(for: asset))
    }

    private func makePendingLivePhoto(resources: [PHAssetResource]) async -> ChatPendingMedia? {
        // 已编辑的 Live Photo 必须成对选 current resources；混用原图和编辑后视频会破坏
        // asset identifier 配对，接收端就无法重新构造 PHLivePhoto。
        let currentPair = (
            resources.first(where: { $0.type == .fullSizePhoto }),
            resources.first(where: { $0.type == .fullSizePairedVideo })
        )
        let originalPair = (
            resources.first(where: { $0.type == .photo }),
            resources.first(where: { $0.type == .pairedVideo })
        )
        let pair = currentPair.0 != nil && currentPair.1 != nil ? currentPair : originalPair
        guard let photo = pair.0,
              let motion = pair.1,
              let photoData = await PHAssetResourceManager.default().data(for: photo),
              let motionData = await PHAssetResourceManager.default().data(for: motion),
              let image = UIImage(data: photoData) else { return nil }
        let photoType = UTType(photo.uniformTypeIdentifier)
        let motionType = UTType(motion.uniformTypeIdentifier)
        let photoMime = photoType?.preferredMIMEType ?? "image/jpeg"
        let motionMime = motionType?.preferredMIMEType ?? "video/quicktime"
        let previewURL = writeTemporaryPreview(data: photoData, preferredExtension: photoType?.preferredFilenameExtension ?? "jpg")
        return ChatPendingMedia(
            id: UUID().uuidString, image: image, data: photoData, mimeType: photoMime,
            messageType: "image", localPreviewURL: previewURL,
            pairedVideoData: motionData, pairedVideoMimeType: motionMime)
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
    func loadLivePhoto() async -> PHLivePhoto? {
        await withCheckedContinuation { continuation in
            loadObject(ofClass: PHLivePhoto.self) { object, _ in
                continuation.resume(returning: object as? PHLivePhoto)
            }
        }
    }

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


private extension PHAssetResourceManager {
    func data(for resource: PHAssetResource) async -> Data? {
        await withCheckedContinuation { continuation in
            var data = Data()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            requestData(for: resource, options: options) { chunk in
                data.append(chunk)
            } completionHandler: { error in
                continuation.resume(returning: error == nil ? data : nil)
            }
        }
    }
}
