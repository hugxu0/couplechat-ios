import SwiftUI

struct FavoriteMediaView: View {
    @EnvironmentObject private var favorites: MediaFavoriteStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var selectedId: String?
    @State private var mediaSourceRegistry = MediaViewerSourceRegistry()

    var body: some View {
        Group {
            if favorites.items.isEmpty {
                ContentUnavailableView {
                    Label("还没有收藏", systemImage: "heart")
                } description: {
                    Text("在聊天图片中长按，选择“收藏”即可保存到这里。")
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: MediaCollectionGrid.columns,
                        spacing: MediaCollectionGrid.spacing
                    ) {
                        ForEach(favorites.items) { item in
                            favoriteTile(item)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(AppPageBackground())
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .background(MediaViewerPresenter(
            items: favorites.items,
            selectedId: $selectedId,
            sourceProvider: { mediaSourceRegistry.view(for: $0) }))
    }

    private func favoriteTile(_ item: MediaBrowserItem) -> some View {
        Button {
            selectedId = item.id
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if item.isVideo, let url = item.mediaURL {
                    VideoThumbnailView(url: url)
                        .aspectRatio(contentMode: .fill)
                } else if let url = item.mediaURL {
                    CachedImage(url: url) {
                        Color.gray.opacity(0.16)
                            .overlay(ProgressView().tint(theme.accent.color))
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
                } else {
                    Color.gray.opacity(0.16)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }

                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .overlay {
                MediaViewerSourceAnchor(id: item.id, registry: mediaSourceRegistry)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                favorites.remove(item)
            } label: {
                Label("取消收藏", systemImage: "heart.slash")
            }
        }
    }
}
