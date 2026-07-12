import SwiftUI

struct FavoriteMediaView: View {
    @EnvironmentObject private var favorites: MediaFavoriteStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var selectedId: String?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 3)]

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
                    LazyVGrid(columns: columns, spacing: 3) {
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
        .background(MediaViewerPresenter(items: favorites.items, selectedId: $selectedId))
    }

    private func favoriteTile(_ item: MediaBrowserItem) -> some View {
        Button {
            selectedId = item.id
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let url = item.mediaURL {
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
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.48), in: Circle())
                        .padding(7)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
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
