import PhotosUI
import SwiftUI

// 主题样式子页：主题色、深浅模式、聊天壁纸（含自定义相册壁纸）一站式切换。
// 从「我的 → 主题样式」进入，取代原来散在我的页里的主题色小圆点。

struct ThemeStyleView: View {
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var app: AppState

    @State private var wallpaperChannel: ChatChannel = .couple
    @State private var customPickerItem: PhotosPickerItem?

    private let wallpaperColumns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.gap) {
                previewCard
                accentCard
                appearanceCard
                wallpaperCard
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(DS.Palette.bgGradient.ignoresSafeArea())
        .navigationTitle("主题样式")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.pushSubpage() }
        .onDisappear { app.popSubpage() }
        .onChange(of: customPickerItem) {
            guard let item = customPickerItem else { return }
            loadCustomImage(item)
        }
    }

    // MARK: - 实时预览（一张小聊天示意，改什么立刻能看见）
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预览")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous)
                    .fill(previewWallpaper.previewGradient)
                    .overlay { previewWallpaper.patternOverlay }

                VStack(spacing: 8) {
                    HStack {
                        Text("今天也想你呀")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Palette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(DS.Palette.bubbleOther, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Text("我也是 💗")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(theme.accent.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(14)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var previewWallpaper: WallpaperChoice {
        theme.wallpaper(for: wallpaperChannel)
    }

    // MARK: - 主题色
    private var accentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("主题色")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)

            HStack(spacing: 14) {
                ForEach(AccentChoice.allCases) { choice in
                    Button {
                        Haptics.selection()
                        withAnimation(DS.Anim.spring) { theme.accent = choice }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(choice.gradient)
                                    .frame(width: 38, height: 38)
                                if theme.accent == choice {
                                    Circle()
                                        .stroke(DS.Palette.textPrimary.opacity(0.85), lineWidth: 2.5)
                                        .frame(width: 46, height: 46)
                                }
                            }
                            .frame(width: 48, height: 48)
                            Text(choice.name)
                                .font(.system(size: 11, weight: theme.accent == choice ? .semibold : .regular))
                                .foregroundStyle(theme.accent == choice ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
                Spacer()
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - 深浅模式
    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("深色模式")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)

            HStack(spacing: 8) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Button {
                        Haptics.selection()
                        withAnimation(DS.Anim.ease) { theme.appearance = choice }
                    } label: {
                        Text(choice.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.appearance == choice ? .white : DS.Palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(theme.appearance == choice
                                ? AnyShapeStyle(theme.accent.color)
                                : AnyShapeStyle(DS.Palette.innerSurface))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - 聊天壁纸
    private var wallpaperCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("聊天壁纸")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)

            // 频道切换：给谁的聊天换壁纸
            HStack(spacing: 8) {
                ForEach(ChatChannel.allCases) { channel in
                    Button {
                        Haptics.selection()
                        withAnimation(DS.Anim.ease) { wallpaperChannel = channel }
                    } label: {
                        Text(channel == .couple ? "两人聊天" : "大橘私聊")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(wallpaperChannel == channel ? .white : DS.Palette.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(wallpaperChannel == channel
                                ? AnyShapeStyle(theme.accent.color)
                                : AnyShapeStyle(DS.Palette.innerSurface))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            LazyVGrid(columns: wallpaperColumns, spacing: 16) {
                ForEach(WallpaperChoice.allCases) { choice in
                    wallpaperTile(choice)
                }
                customTile
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func wallpaperTile(_ choice: WallpaperChoice) -> some View {
        let hasCustom = theme.hasCustomWallpaper(for: wallpaperChannel)
        let selected = !hasCustom && theme.wallpaper(for: wallpaperChannel) == choice
        return Button {
            Haptics.selection()
            theme.removeCustomWallpaper(for: wallpaperChannel)
            withAnimation(DS.Anim.spring) {
                theme.setWallpaper(choice, for: wallpaperChannel)
            }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(choice.previewGradient)
                    .frame(height: 110)
                    .overlay { choice.patternOverlay }
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
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textSecondary)
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var customTile: some View {
        let isCustom = theme.hasCustomWallpaper(for: wallpaperChannel)
        return PhotosPicker(selection: $customPickerItem, matching: .images) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isCustom ? AnyShapeStyle(DS.Palette.accent.opacity(0.12)) : AnyShapeStyle(Color.gray.opacity(0.1)))
                    .frame(height: 110)
                    .overlay {
                        if isCustom, let img = theme.customWallpaperImage(for: wallpaperChannel) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: 110)
                                .clipped()
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 24))
                                Text("从相册选")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isCustom ? DS.Palette.accent : .clear, lineWidth: 3)
                    )
                HStack(spacing: 4) {
                    if isCustom {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Palette.accent)
                    }
                    Text(isCustom ? "已自定义" : "自定义")
                        .font(.system(size: 13, weight: isCustom ? .semibold : .regular))
                        .foregroundStyle(isCustom ? DS.Palette.accent : DS.Palette.textSecondary)
                }
                if isCustom {
                    Button(role: .destructive) {
                        theme.removeCustomWallpaper(for: wallpaperChannel)
                    } label: {
                        Text("移除")
                            .font(.system(size: 11))
                    }
                }
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
                theme.setCustomWallpaper(imageData: jpeg, for: wallpaperChannel)
                customPickerItem = nil
            }
        }
    }
}
