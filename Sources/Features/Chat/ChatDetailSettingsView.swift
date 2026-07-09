import SwiftUI

// MARK: - 聊天详情 / 管理页

struct ChatDetailSettingsView: View {
    let channel: ChatChannel
    let partnerName: String
    let partnerAvatar: String
    let partnerOnline: Bool
    let onJumpToMessage: (ChatMessage) -> Void
    let onJumpToDate: (Date) -> Void

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showSearch = false
    @State private var showMedia = false
    @State private var showWallpaper = false
    @State private var showAliasPrompt = false
    @State private var aliasText = ""

    /// 当前展示名：优先本地备注，其次账号昵称
    private var displayName: String {
        channel == .ai ? partnerName : store.partnerDisplayName(fallback: partnerName)
    }

    private var partnerUsername: String? {
        store.partner?.username ?? (store.session?.username == "xu" ? "si" : "xu")
    }

    @AppStorage("chat_muted") private var chatMuted: Bool = false

    private var mediaItemCount: Int {
        store.mediaItemCount(for: channel, includeFiles: true)
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
                onJump: { msg in
                    onJumpToMessage(msg)
                    dismiss()
                },
                onJumpDate: { date in
                    onJumpToDate(date)
                    dismiss()
                }
            )
        }
        .sheet(isPresented: $showMedia) {
            MediaGallerySheet(channel: channel)
        }
        .sheet(isPresented: $showWallpaper) {
            WallpaperPickerSheet(channel: channel)
                .presentationDetents([.medium, .large])
        }
        .alert("设置备注", isPresented: $showAliasPrompt) {
            TextField("备注名（最多 12 字）", text: $aliasText)
            Button("保存") { saveAlias() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅自己可见，不会同步给对方")
        }
        // 子页保持底部标签栏隐藏
        .onAppear { app.pushSubpage() }
        .onDisappear { app.popSubpage() }
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
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(partnerOnline ? "在线" : "离线")
                        .font(.system(size: 13, weight: .medium))
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
            if channel == .couple, let url = store.avatarURL(for: store.partner?.username) {
                CachedImage(url: url) {
                    Text(partnerAvatar)
                        .font(.system(size: emojiSize))
                        .frame(width: size, height: size)
                        .background(theme.accent.color.opacity(0.10))
                }
            } else {
                Text(partnerAvatar)
                    .font(.system(size: emojiSize))
                    .frame(width: size, height: size)
                    .background(theme.accent.color.opacity(0.10))
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
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
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
                    .font(.system(size: 14))
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
            HStack {
                Label("消息免打扰", systemImage: "bell.slash.fill")
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Toggle("", isOn: $chatMuted)
                    .labelsHidden()
            }

            Button {
                showWallpaper = true
            } label: {
                Label("更换聊天背景", systemImage: "paintpalette")
                    .foregroundStyle(DS.Palette.textPrimary)
            }
        }
    }
}
