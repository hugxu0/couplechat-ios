import SwiftUI

struct OnThisDayCard: View {
    let moment: OnThisDayMoment

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("那年今日", systemImage: "clock.arrow.circlepath")
                        .font(DS.Typo.cardTitle)
                    Text(moment.title)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Text("\(moment.yearsAgo) 年前")
                    .font(DS.Typo.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.purple)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DS.Palette.purple.opacity(0.12), in: Capsule())
            }
            MomentMosaic(assets: Array(moment.assets.prefix(4)))
                .frame(height: 190)
            Text(moment.date)
                .font(DS.Typo.caption)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(DS.Spacing.card)
        .dsCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("那年今日，\(moment.yearsAgo)年前，\(moment.title)，共\(moment.assets.count)项")
    }
}

struct MomentAlbumCard: View {
    let album: MomentAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.compact) {
            MomentMosaic(assets: album.previewItems, fallbackURL: album.resolvedCoverURL)
                .frame(height: 152)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                    if let note = album.note, !note.isEmpty {
                        Text(note)
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(1)
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

struct MomentMosaic: View {
    let assets: [MomentAsset]
    var fallbackURL: URL? = nil

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let width = proxy.size.width
            if assets.count >= 3 {
                HStack(spacing: gap) {
                    tile(assets[0], width: width * 0.62)
                    VStack(spacing: gap) {
                        tile(assets[1], width: width * 0.38 - gap)
                        tile(assets[2], width: width * 0.38 - gap)
                    }
                }
            } else if assets.count == 2 {
                HStack(spacing: gap) {
                    tile(assets[0], width: (width - gap) / 2)
                    tile(assets[1], width: (width - gap) / 2)
                }
            } else {
                tile(assets.first, fallbackURL: fallbackURL, width: width)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func tile(_ asset: MomentAsset?, fallbackURL: URL? = nil, width: CGFloat) -> some View {
        CachedImage(url: asset?.resolvedURL ?? fallbackURL) {
            ZStack {
                DS.Palette.innerSurface
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if asset?.isVideo == true {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.36), in: Circle())
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
