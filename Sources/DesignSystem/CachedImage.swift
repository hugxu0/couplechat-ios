import SwiftUI

// 走 ImageCache 的图片视图，命中缓存立即出图（不闪 loading），未命中再异步下载。

struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImageCache.shared.cachedImage(for: url) {
                image = hit
            } else {
                image = await ImageCache.shared.image(for: url)
            }
        }
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
            Text(fallbackEmoji)
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
                .background(background)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
