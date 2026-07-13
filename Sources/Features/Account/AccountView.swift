import SwiftUI
import PhotosUI

// 我的页：身份卡 + 外观（主题色/深浅模式）+ 日期设置 + 离线通知 + 退出登录。

struct AccountView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var showDateEditor = false
    @State private var showBarkSheet = false
    @State private var showLogoutConfirm = false

    // 头像更换
    @State private var customAvatar: UIImage?
    @State private var showAvatarActionSheet = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var avatarUploading = false
    @State private var pendingCameraUpload = false
    @State private var avatarTarget: AvatarTarget = .me

    private var myEmoji: String {
        AccountPresentation.avatar(for: store.session?.username ?? "xu")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    header
                    settingsCard
                    logoutCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDateEditor) {
                DateEditorSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showBarkSheet) {
                BarkSettingsSheet()
                    .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showCamera) {
                AccountCameraPicker(image: $customAvatar)
                    .ignoresSafeArea()
            }
            .confirmationDialog("更换头像", isPresented: $showAvatarActionSheet, titleVisibility: .visible) {
                if avatarTarget == .daju {
                    Button("使用默认大橘头像") {
                        useDefaultDajuAvatar()
                    }
                }
                Button("从手机相册选择") {
                    showPhotoPicker = true
                }
                Button("拍照") {
                    pendingCameraUpload = true
                    showCamera = true
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("确定退出登录吗？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Haptics.medium()
                    store.logout()
                }
            }
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                loadAndUpload(from: item)
            }
            .onChange(of: customAvatar) { _, image in
                guard let image, pendingCameraUpload else { return }
                pendingCameraUpload = false
                avatarUploading = true
                Task {
                    _ = await uploadAvatar(image)
                    await MainActor.run { avatarUploading = false }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        }
    }

    private func loadAndUpload(from item: PhotosPickerItem) {
        avatarUploading = true
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                await MainActor.run {
                    customAvatar = image
                }
                _ = await uploadAvatar(image)
            }
            await MainActor.run {
                avatarUploading = false
                selectedPhotoItem = nil
            }
        }
    }

    private func uploadAvatar(_ image: UIImage) async -> Bool {
        switch avatarTarget {
        case .me:
            return await store.uploadAvatar(image)
        case .daju:
            return await store.uploadDajuAvatar(image)
        }
    }

    private func openAvatarPicker(for target: AvatarTarget) {
        avatarTarget = target
        customAvatar = nil
        showAvatarActionSheet = true
    }

    private func useDefaultDajuAvatar() {
        avatarUploading = true
        let image = Self.defaultDajuAvatarImage(accent: theme.accent.uiColor)
        Task {
            _ = await store.uploadDajuAvatar(image)
            await MainActor.run { avatarUploading = false }
        }
    }

    private static func defaultDajuAvatarImage(accent: UIColor) -> UIImage {
        let size = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            context.cgContext.setFillColor(accent.withAlphaComponent(0.13).cgColor)
            context.cgContext.fillEllipse(in: bounds)

            let configuration = UIImage.SymbolConfiguration(pointSize: 238, weight: .medium)
            let symbol = UIImage(systemName: AccountPresentation.dajuIconName, withConfiguration: configuration)?
                .withTintColor(accent, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 137, y: 137, width: 238, height: 238))
        }
    }

    // MARK: - 身份横栏
    private var header: some View {
        HStack(spacing: DS.Spacing.card - 4) {
            avatarView
                .onTapGesture {
                    Haptics.light()
                    openAvatarPicker(for: .me)
                }

            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                Text(store.session?.name ?? "未登录")
                    .font(DS.Typo.button)
                    .foregroundStyle(DS.Palette.textPrimary)
                if let partner = store.partner {
                    HStack(spacing: DS.Spacing.tight) {
                        Text("和")
                        Text(partner.name).fontWeight(.semibold).foregroundStyle(theme.accent.color)
                        Text("在一起")
                    }
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                }
                Text(store.connected ? "已连接 · hoo66.top" : (store.lastConnectionError ?? "未连接"))
                    .font(DS.Typo.caption.weight(.medium))
                    .foregroundStyle(store.connected ? DS.Palette.textSecondary : DS.Palette.red)
            }

            Spacer()

            Button {
                Haptics.light()
                openAvatarPicker(for: .me)
            } label: {
                Image(systemName: "camera.fill")
                    .font(DS.Typo.secondary.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(theme.accent.color, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("更换头像")
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.vertical, DS.Spacing.card - 4)
        .dsCard()
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if avatarTarget == .me, let avatar = customAvatar {
                // 刚选好还没传完时的即时反馈
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
            } else if let url = store.avatarURL(for: store.session?.username) {
                CachedImage(url: url) {
                    Text(myEmoji)
                        .font(DS.Typo.pageTitle)
                        .frame(width: 52, height: 52)
                        .background(theme.accent.color.opacity(0.12))
                }
            } else {
                Text(myEmoji)
                    .font(DS.Typo.pageTitle)
                    .frame(width: 52, height: 52)
                    .background(theme.accent.color.opacity(0.12))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(theme.accent.color.opacity(0.35), lineWidth: 2))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(store.connected ? DS.Palette.green : DS.Palette.red)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 2))
        }
    }

    // MARK: - 设置项
    private var settingsCard: some View {
        VStack(spacing: 0) {
            settingRowLabelWithAvatar(
                icon: "pawprint",
                title: "大橘头像",
                subtitle: "更换大橘在聊天里的头像",
                avatarURL: store.avatarURL(for: "ai"),
                avatarText: store.avatarText(for: "ai")
            ) {
                openAvatarPicker(for: .daju)
            }
            divider
            NavigationLink {
                ThemeStyleView().appSubpageChrome()
            } label: {
                settingRowLabel(icon: "paintpalette", title: "主题样式", subtitle: "主题色 · 深色模式 · 聊天壁纸")
            }
            .buttonStyle(PressableStyle())
            divider
            NavigationLink {
                AIMemoryControlCenterView().appSubpageChrome()
            } label: {
                settingRowLabel(icon: "pawprint.circle", title: "大橘与记忆", subtitle: "查看、纠正或忘掉记忆")
            }
            .buttonStyle(PressableStyle())
            divider
            settingRow(icon: "calendar.badge.plus", title: "日期设置", subtitle: "在一起的纪念日") {
                showDateEditor = true
            }
            divider
            settingRow(icon: "bell.badge", title: "离线通知", subtitle: "对方消息 Bark 推送") {
                showBarkSheet = true
            }
            divider
            NavigationLink {
                AccountDevicesView().appSubpageChrome()
            } label: {
                settingRowLabel(icon: "iphone.and.arrow.forward", title: "配对与设备", subtitle: "邀请码 · 手机与 iPad 登录")
            }
            .buttonStyle(PressableStyle())
            divider
            NavigationLink {
                StorageView().appSubpageChrome()
            } label: {
                settingRowLabel(icon: "internaldrive", title: "存储空间", subtitle: "同步聊天记录 · 缓存管理")
            }
            .buttonStyle(PressableStyle())
            divider
            NavigationLink {
                FavoriteMediaView().appSubpageChrome()
            } label: {
                settingRowLabel(icon: "heart", title: "收藏", subtitle: "聊天图片与视频")
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.vertical, 6)
        .dsCard()
    }

    private var logoutCard: some View {
        Button {
            Haptics.light()
            showLogoutConfirm = true
        } label: {
            Text("退出登录")
                .font(DS.Typo.button)
                .foregroundStyle(DS.Palette.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.card - 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .dsCard()
    }

    private var divider: some View {
        Divider().padding(.leading, 58).opacity(0.5)
    }

    private func settingRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            settingRowLabel(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(PressableStyle())
    }

    private func settingRowLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: DS.Spacing.card - 4) {
            Image(systemName: icon)
                .font(DS.Typo.button)
                .foregroundStyle(theme.accent.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(subtitle)
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.vertical, DS.Spacing.gap)
        .contentShape(Rectangle())
    }

    private func settingRowLabelWithAvatar(
        icon: String,
        title: String,
        subtitle: String,
        avatarURL: URL?,
        avatarText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: DS.Spacing.card - 4) {
                Image(systemName: icon)
                    .font(DS.Typo.button)
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(subtitle)
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                AvatarBadge(
                    url: avatarURL,
                    fallbackEmoji: avatarText,
                    size: 32,
                    background: theme.accent.color.opacity(0.12)
                )
                Image(systemName: "chevron.right")
                    .font(DS.Typo.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, DS.Spacing.card)
            .padding(.vertical, DS.Spacing.gap - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private enum AvatarTarget: Equatable {
    case me
    case daju
}
