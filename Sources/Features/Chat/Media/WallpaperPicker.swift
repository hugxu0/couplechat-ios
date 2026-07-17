import SwiftUI
import PhotosUI

struct WallpaperPickerSheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var customPickerItem: PhotosPickerItem?
    @State private var wallpaperAppearance: WallpaperAppearance = .light

    private var columns: [GridItem] {
        [GridItem(.adaptive(
            minimum: dynamicTypeSize.isAccessibilitySize ? 140 : 96,
            maximum: 180), spacing: 14)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Picker("显示模式", selection: $wallpaperAppearance) {
                        ForEach(WallpaperAppearance.allCases) { appearance in
                            Text(appearance.name).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(WallpaperChoice.allCases) { choice in
                            wallpaperTile(choice)
                        }
                        ForEach(theme.customWallpapers(for: channel, appearance: wallpaperAppearance)) { asset in
                            customWallpaperTile(asset)
                        }
                        addCustomTile
                    }
                }
                .padding(DS.Spacing.page)
            }
            .navigationTitle("聊天壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: customPickerItem) {
                guard let item = customPickerItem else { return }
                loadCustomImage(item)
            }
            .onAppear {
                wallpaperAppearance = WallpaperAppearance(colorScheme: colorScheme)
            }
        }
    }

    private func wallpaperTile(_ choice: WallpaperChoice) -> some View {
        let hasCustom = theme.hasCustomWallpaper(for: channel, appearance: wallpaperAppearance)
        let selected = !hasCustom && theme.wallpaper(for: channel, appearance: wallpaperAppearance) == choice
        return Button {
            Haptics.selection()
            theme.clearCustomWallpaperSelection(for: channel, appearance: wallpaperAppearance)
            withAnimation(DS.Anim.spring) {
                theme.setWallpaper(choice, for: channel, appearance: wallpaperAppearance)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    WallpaperPreviewSurface(choice: choice, height: 120)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(.white.opacity(0.85)).frame(width: 42, height: 12)
                        Capsule().fill(DS.Palette.accent.opacity(0.9)).frame(width: 34, height: 12)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected ? DS.Palette.accent : .clear, lineWidth: 3)
                )
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Palette.accent)
                    }
                    Text(choice.name)
                        .font(DS.Typo.caption.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textSecondary)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func customWallpaperTile(_ asset: CustomWallpaperAsset) -> some View {
        let selected = theme.selectedCustomWallpaperID(
            for: channel,
            appearance: wallpaperAppearance) == asset.id
        return Button {
            Haptics.selection()
            withAnimation(DS.Anim.spring) {
                theme.selectCustomWallpaper(id: asset.id, for: channel, appearance: wallpaperAppearance)
            }
        } label: {
            VStack(spacing: 8) {
                Group {
                    if let image = theme.customWallpaperImage(
                        id: asset.id,
                        for: channel,
                        appearance: wallpaperAppearance) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.gray.opacity(0.1)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected ? DS.Palette.accent : .clear, lineWidth: 3)
                )
                Label(selected ? "使用中" : "已保存", systemImage: selected ? "checkmark.circle.fill" : "photo")
                    .font(DS.Typo.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textSecondary)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button(role: .destructive) {
                theme.removeCustomWallpaper(
                    id: asset.id,
                    for: channel,
                    appearance: wallpaperAppearance)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var addCustomTile: some View {
        return PhotosPicker(selection: $customPickerItem, matching: .images) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.gray.opacity(0.1))
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("添加到\(wallpaperAppearance.name)图库")
                    .font(DS.Typo.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .buttonStyle(PressableStyle())
    }

    private func loadCustomImage(_ item: PhotosPickerItem) {
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            await MainActor.run {
                theme.addCustomWallpaper(
                    imageData: jpeg,
                    for: channel,
                    appearance: wallpaperAppearance)
                customPickerItem = nil
            }
        }
    }
}
