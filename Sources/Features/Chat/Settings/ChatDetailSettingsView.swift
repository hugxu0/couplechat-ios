import SwiftUI

// MARK: - 聊天详情 / 管理页

struct ChatDetailSettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let channel: ChatChannel
    let partnerName: String
    let partnerAvatar: String
    let partnerOnline: Bool
    let onJumpToMessage: (ChatMessage) -> Void
    let onJumpToDate: (Date) -> Void

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var showSearch = false
    @State private var showMedia = false
    @State private var showWallpaper = false
    @State private var showAliasPrompt = false
    @State private var aliasText = ""
    @State private var mediaItemCount = 0

    /// 当前展示名：优先本地备注，其次账号昵称
    private var displayName: String {
        channel == .ai ? partnerName : store.partnerDisplayName(fallback: partnerName)
    }

    private var partnerUsername: String? {
        store.partner?.username ?? (store.session?.username == "xu" ? "si" : "xu")
    }

    private var avatarUsername: String? {
        channel == .ai ? "ai" : partnerUsername
    }

    var body: some View {
        List {
            identitySection
            actionSection
            settingsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("聊天详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSearch) {
            ChatSearchSheet(
                channel: channel,
                onJump: onJumpToMessage,
                onJumpDate: onJumpToDate
            )
            .presentationSizing(.form)
        }
        .sheet(isPresented: $showMedia) {
            MediaGallerySheet(channel: channel)
                .presentationSizing(.form)
        }
        .sheet(isPresented: $showWallpaper) {
            WallpaperPickerSheet(channel: channel)
                .presentationDetents([.medium, .large])
                .presentationSizing(.form)
        }
        .alert("设置备注", isPresented: $showAliasPrompt) {
            TextField("备注名（最多 12 字）", text: $aliasText)
            Button("保存") { saveAlias() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅自己可见，不会同步给对方")
        }
        .task {
            mediaItemCount = await store.mediaItemCount(for: channel, includeFiles: true)
        }
    }

    private func saveAlias() {
        Haptics.light()
        // ai 频道不支持备注；couple 频道按对方账号存本地备注
        guard channel == .couple else { return }
        store.setPartnerAlias(aliasText, for: partnerUsername)
    }

    // MARK: - Section 1: 身份横栏

    private var identitySection: some View {
        Section {
            HStack(spacing: 12) {
                avatar(size: 46, emojiSize: 27)

                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(DS.Typo.body.weight(.semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(partnerOnline ? "在线" : "离线")
                        .font(DS.Typo.caption.weight(.medium))
                        .foregroundStyle(partnerOnline ? DS.Palette.green : DS.Palette.textSecondary)
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func avatar(size: CGFloat, emojiSize: CGFloat) -> some View {
        Group {
            if let url = store.avatarURL(for: avatarUsername) {
                CachedImage(url: url) {
                    avatarPlaceholder(size: size, emojiSize: emojiSize)
                }
            } else {
                avatarPlaceholder(size: size, emojiSize: emojiSize)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(theme.accent.color.opacity(0.22), lineWidth: 1.4))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(partnerOnline ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.55))
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        }
    }

    @ViewBuilder
    private func avatarPlaceholder(size: CGFloat, emojiSize: CGFloat) -> some View {
        if partnerAvatar == AccountPresentation.dajuDefaultEmoji {
            Image(systemName: AccountPresentation.dajuIconName)
                .font(.system(size: emojiSize * 0.82, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(theme.accent.color.opacity(0.10))
        } else {
            Text(partnerAvatar)
                .font(.system(size: emojiSize))
                .frame(width: size, height: size)
                .background(theme.accent.color.opacity(0.10))
        }
    }

    // MARK: - Section 2: 功能入口

    private var actionSection: some View {
        Section {
            Button {
                aliasText = store.partnerAlias(for: partnerUsername) ?? ""
                showAliasPrompt = true
            } label: {
                HStack {
                    Label("设置备注", systemImage: "pencil")
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text(displayName)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                }
            }

            Button {
                showSearch = true
            } label: {
                Label("搜索聊天记录", systemImage: "magnifyingglass")
                    .foregroundStyle(DS.Palette.textPrimary)
            }

            mediaRow
        }
    }

    private var mediaRow: some View {
        Button {
            showMedia = true
        } label: {
            HStack {
                Label("媒体与文件", systemImage: "photo.on.rectangle")
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text("\(mediaItemCount) 项")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
            }
        }
    }

    // MARK: - Section 3: 聊天设置

    private var settingsSection: some View {
        Section {
            Button {
                showWallpaper = true
            } label: {
                Label("更换聊天背景", systemImage: "paintpalette")
                    .foregroundStyle(DS.Palette.textPrimary)
            }
        }
    }
}
