import SwiftUI

struct MomentAlbumCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let album: MomentAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.compact) {
            MomentAlbumPreview(assets: album.previewItems, fallbackURL: album.resolvedCoverURL)
                .frame(height: 120)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    if let note = album.note, !note.isEmpty {
                        Text(note)
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    }
                }
                Spacer(minLength: 8)
                Text("\(album.itemCount)")
                    .font(DS.Typo.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .dsCard(radius: DS.Radius.tile)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("相册 \(album.title)，\(album.itemCount)项")
        .accessibilityHint("轻点打开相册")
    }
}

private struct MomentAlbumPreview: View {
    let assets: [MomentAsset]
    let fallbackURL: URL?

    private var visibleAssets: [MomentAsset] {
        Array(assets.prefix(2))
    }

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 4
            if visibleAssets.count == 2 {
                let side = max(0, min(proxy.size.height, (proxy.size.width - gap) / 2))
                HStack(spacing: gap) {
                    tile(visibleAssets[0])
                        .frame(width: side, height: side)
                    tile(visibleAssets[1])
                        .frame(width: side, height: side)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                tile(visibleAssets.first, fallbackURL: fallbackURL)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func tile(_ asset: MomentAsset?, fallbackURL: URL? = nil) -> some View {
        Group {
            if let asset, asset.isVideo, let url = asset.resolvedOriginalURL {
                VideoThumbnailView(url: url, contentMode: .fill)
            } else {
                CachedImage(url: asset?.resolvedURL ?? fallbackURL, contentMode: .fill) {
                    ZStack {
                        DS.Palette.innerSurface
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .clipped()
        .overlay(alignment: .topTrailing) {
            if asset?.isVideo == true {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.38), in: Circle())
                    .padding(7)
            }
        }
    }
}

struct AlbumCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String?) async -> Bool
    @State private var title = ""
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("相册") {
                    TextField("例如：一起看过的海", text: $title)
                        .textInputAutocapitalization(.never)
                    TextField("写一句共同注脚（可选）", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    Text("创建后，可在聊天图片或视频的长按菜单中加入相册。")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .navigationTitle("新建共同相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "创建") {
                        Task {
                            saving = true
                            if await onSave(trimmedTitle, trimmedNote) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || saving)
                }
            }
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedNote: String? {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
