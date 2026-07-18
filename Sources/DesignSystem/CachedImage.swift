import SwiftUI

// 走 ImageCache 的图片视图，命中缓存立即出图（不闪 loading），未命中再异步下载。

struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var onImageSizeChange: ((CGSize) -> Void)?
    let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(
        url: URL?,
        contentMode: ContentMode = .fill,
        onImageSizeChange: ((CGSize) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.contentMode = contentMode
        self.onImageSizeChange = onImageSizeChange
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                if image.images?.isEmpty == false {
                    AnimatedCachedImage(image: image, contentMode: contentMode)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            // 内存命中同步取，避免闪一下占位；否则后台异步加载
            if let hit = ImageCache.shared.memoryImage(for: url) {
                image = hit
            } else {
                image = await ImageCache.shared.previewImage(
                    for: url,
                    thumbnailURL: ServerConfig.mediaThumbnailURL(for: url))
            }
        }
        .onChange(of: image?.size) { _, size in
            guard let size, size.width > 0, size.height > 0 else { return }
            onImageSizeChange?(size)
        }
    }
}

/// SwiftUI's `Image(uiImage:)` displays only the first frame of an animated UIImage.
/// Keep the normal SwiftUI rendering path for still images and bridge only animations.
private struct AnimatedCachedImage: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        guard view.image !== image || view.contentMode != uiContentMode else { return }
        view.stopAnimating()
        view.image = image
        view.contentMode = uiContentMode
        view.startAnimating()
    }

    private var uiContentMode: UIView.ContentMode {
        contentMode == .fit ? .scaleAspectFit : .scaleAspectFill
    }
}

/// 圆形头像：有上传头像走缓存图，否则回退 emoji 占位。
struct AvatarBadge: View {
    let url: URL?
    let fallbackEmoji: String
    var size: CGFloat = 40
    var background: Color = DS.Palette.bubbleOther

    var body: some View {
        CachedImage(url: url) {
            Group {
                if fallbackEmoji == AccountPresentation.dajuDefaultEmoji {
                    Image(systemName: AccountPresentation.dajuIconName)
                        .font(.system(size: size * 0.47, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text(fallbackEmoji)
                        .font(.system(size: size * 0.55))
                }
            }
            .frame(width: size, height: size)
            .background(background)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
