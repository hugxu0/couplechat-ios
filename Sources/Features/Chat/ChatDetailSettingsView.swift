import SwiftUI

// MARK: - 聊天详情 / 管理页

struct ChatDetailSettingsView: View {
    let channel: ChatChannel
    let partnerName: String
    let partnerAvatar: String
    let partnerOnline: Bool

    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showSearch = false
    @State private var showMedia = false
    @State private var showWallpaper = false
    @State private var showAliasPrompt = false
    @State private var aliasText = ""

    @AppStorage("chat_muted") private var chatMuted: Bool = false

    private var mediaMessages: [ChatMessage] {
        store.messages(for: channel).filter {
            ($0.type == "image" || $0.type == "video" || $0.type == "sticker") && !$0.pending
        }
    }

    var body: some View {
        List {
            partnerSection
            contentSection
            settingsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("聊天详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSearch) {
            ChatSearchSheet(channel: channel, scrollToMessageId: .constant(nil))
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
            Button("保存") { Haptics.light() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅自己可见，不会同步给对方")
        }
        .onAppear { aliasText = partnerName }
    }

    // MARK: - Section 1: 头像 & 身份

    private var partnerSection: some View {
        Section {
            VStack(spacing: 10) {
                Text(partnerAvatar)
                    .font(.system(size: 48))
                    .frame(width: 84, height: 84)
                    .background(theme.accent.color.opacity(0.10))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(theme.accent.color.opacity(0.25), lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(partnerOnline ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.5))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                            .offset(x: 2, y: 2)
                    }

                Text(aliasText.isEmpty ? partnerName : aliasText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)

                Text(partnerOnline ? "在线" : "离线")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(partnerOnline ? DS.Palette.green : DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            Button {
                aliasText = aliasText.isEmpty ? partnerName : aliasText
                showAliasPrompt = true
            } label: {
                HStack {
                    Label("设置备注", systemImage: "pencil")
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text(aliasText.isEmpty ? partnerName : aliasText)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                }
            }
        }
    }

    // MARK: - Section 2: 内容查找

    private var contentSection: some View {
        Section {
            Button {
                showSearch = true
            } label: {
                Label("查找聊天记录", systemImage: "magnifyingglass")
                    .foregroundStyle(DS.Palette.textPrimary)
            }

            mediaRow
        }
    }

    // MARK: 横向滚动媒体缩略图

    private var mediaRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showMedia = true
            } label: {
                HStack {
                    Label("媒体与文件", systemImage: "photo.on.rectangle")
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text("\(mediaMessages.count) 项")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                }
            }

            if mediaMessages.isEmpty {
                Text("暂无图片或视频")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(mediaMessages.suffix(10).reversed())) { msg in
                            mediaThumbnail(msg)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func mediaThumbnail(_ message: ChatMessage) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(mediaThumbColor(index: message.text.hashValue))
            .frame(width: 64, height: 64)
            .overlay {
                if message.type == "video" {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                } else if message.type == "sticker" {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .onTapGesture { showMedia = true }
    }

    private func mediaThumbColor(index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 1.00, green: 0.55, blue: 0.62),
            Color(red: 0.99, green: 0.72, blue: 0.52),
            Color(red: 0.98, green: 0.75, blue: 0.82),
            Color(red: 0.95, green: 0.64, blue: 0.48),
            Color(red: 0.78, green: 0.58, blue: 0.88),
        ]
        return palette[abs(index) % palette.count].opacity(0.65)
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
