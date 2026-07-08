import AVFoundation
import SwiftUI
import UIKit

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
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
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage).preparingForDisplay() ?? UIImage(cgImage: cgImage)
        }.value
        thumbnail = image
    }
}
