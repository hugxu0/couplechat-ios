import SwiftUI
import PhotosUI

// MARK: - 更换壁纸

struct WallpaperPickerSheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var customPickerItem: PhotosPickerItem?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(WallpaperChoice.allCases) { choice in
                        wallpaperTile(choice)
                    }
                    customTile
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
        }
    }

    private func wallpaperTile(_ choice: WallpaperChoice) -> some View {
        let hasCustom = theme.hasCustomWallpaper(for: channel)
        let selected = !hasCustom && theme.wallpaper(for: channel) == choice
        return Button {
            Haptics.selection()
            theme.removeCustomWallpaper(for: channel)
            withAnimation(DS.Anim.spring) {
                theme.setWallpaper(choice, for: channel)
            }
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(choice.previewGradient)
                    .frame(height: 120)
                    .overlay { choice.patternOverlay }
                    .overlay(
                        VStack(alignment: .leading, spacing: 4) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 42, height: 12)
                            Capsule().fill(DS.Palette.accent.opacity(0.9)).frame(width: 34, height: 12)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(10)
                    )
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
        let isCustom = theme.hasCustomWallpaper(for: channel)
        return PhotosPicker(selection: $customPickerItem, matching: .images) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isCustom ? AnyShapeStyle(DS.Palette.accent.opacity(0.12)) : AnyShapeStyle(Color.gray.opacity(0.1)))
                    .frame(height: 120)
                    .overlay {
                        if isCustom, let img = theme.customWallpaperImage(for: channel) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: 120)
                                .clipped()
                        } else {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 28))
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
                        theme.removeCustomWallpaper(for: channel)
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
                theme.setCustomWallpaper(imageData: jpeg, for: channel)
                customPickerItem = nil
            }
        }
    }
}

// MARK: - AI Actions 确认卡（大橘提议建提醒/备忘，主人确认后才真正写入）

struct ActionConfirmCard: View {
    @EnvironmentObject private var store: ChatStore
    let messageId: String
    let confirm: ActionConfirm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(confirm.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: item.action.type))
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if confirm.status == "pending" {
                HStack(spacing: 10) {
                    Button {
                        store.confirmAction(messageId: messageId, decision: "confirm")
                    } label: {
                        Text("确认")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(DS.Palette.accent, in: Capsule())
                    }
                    Button {
                        store.confirmAction(messageId: messageId, decision: "cancel")
                    } label: {
                        Text("取消")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(DS.Palette.bubbleOther, in: Capsule())
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: confirm.status == "confirmed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(confirm.status == "confirmed" ? DS.Palette.green : DS.Palette.textSecondary)
                    Text(confirm.status == "confirmed" ? "已确认" : "已取消")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .padding(12)
        .background(DS.Palette.bubbleOther.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Palette.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "add_reminder": return "bell.badge"
        case "add_memo": return "note.text"
        case "complete_reminder": return "checkmark.circle"
        case "delete_reminder": return "trash"
        case "edit_memo": return "pencil.line"
        default: return "pawprint"
        }
    }
}

// MARK: - 联网搜索来源卡片

struct SearchCitationsCard: View {
    let items: [SearchCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                Text("来源")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.Palette.textSecondary)

            ForEach(items) { item in
                if let url = URL(string: item.url) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DS.Palette.accent)
                                .lineLimit(2)
                            Text(item.url)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(DS.Palette.bubbleOther.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
