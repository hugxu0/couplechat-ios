import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

struct VideoThumbnailView: View {
    let url: URL
    var contentMode: ContentMode = .fill
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                LinearGradient(
                    colors: [.black.opacity(0.16), .black.opacity(0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        thumbnail = await VideoThumbnailGenerator.image(for: url)
    }
}

@MainActor
enum VideoThumbnailGenerator {
    private static var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private static var failedAt: [URL: Date] = [:]

    static func image(for url: URL) async -> UIImage? {
        let cacheURL = thumbnailCacheURL(for: url)
        if let cached = await ImageCache.shared.cachedImage(for: cacheURL) { return cached }
        if let failed = failedAt[url], Date().timeIntervalSince(failed) < 20 { return nil }
        if let task = inFlight[url] { return await task.value }

        // AVAssetImageGenerator 会配合服务端 Range 读取所需片段。失败时保留占位图，
        // 不再为了一个缩略图后台下载完整视频并与播放器争抢带宽。
        let task = Task { await generateImage(for: url) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image, let data = image.jpegData(compressionQuality: 0.82) {
            failedAt[url] = nil
            ImageCache.shared.store(data: data, image: image, for: cacheURL)
        } else {
            failedAt[url] = Date()
        }
        return image
    }

    nonisolated private static func generateImage(for url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let times = [CMTime(seconds: 0.1, preferredTimescale: 600), .zero]
            for time in times {
                if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                    return UIImage(cgImage: cgImage).preparingForDisplay() ?? UIImage(cgImage: cgImage)
                }
            }
            return nil
        }.value
    }

    private static func thumbnailCacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(string: "cc-video-thumbnail://cache/\(digest)")!
    }
}
