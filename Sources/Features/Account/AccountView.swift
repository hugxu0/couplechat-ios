import SwiftUI
import PhotosUI

// 我的页：身份卡 + 外观（主题色/深浅模式）+ 日期设置 + 离线通知 + 退出登录。

struct AccountView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var showDateEditor = false
    @State private var showBarkSheet = false
    @State private var showLogoutConfirm = false

    // 头像更换
    @State private var customAvatar: UIImage?
    @State private var avatarMenuSource: AvatarMenuSource?
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
                .appReadableWidth(760)
            }
            .scrollIndicators(.hidden)
            .background(AppPageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDateEditor) {
                DateEditorSheet()
                    .presentationDetents([.medium])
                    .presentationSizing(.form)
            }
            .sheet(isPresented: $showBarkSheet) {
                BarkSettingsSheet()
                    .presentationDetents([.medium])
                    .presentationSizing(.form)
            }
            .fullScreenCover(isPresented: $showCamera) {
                AccountCameraPicker(image: $customAvatar)
                    .ignoresSafeArea()
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

    private func openAvatarMenu(from source: AvatarMenuSource) {
        avatarTarget = source.target
        customAvatar = nil
        avatarMenuSource = source
    }

    private func avatarMenuPresented(for source: AvatarMenuSource) -> Binding<Bool> {
        Binding(
            get: { avatarMenuSource == source },
            set: { isPresented in
                if !isPresented, avatarMenuSource == source { avatarMenuSource = nil }
            })
    }

    private func deferAvatarPresentation(_ action: @escaping () -> Void) {
        avatarMenuSource = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: action)
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DS.Spacing.gap) {
                    HStack {
                        profileAvatarButton
                        Spacer()
                        profileCameraButton
                    }
                    identityBlock
                }
            } else {
                HStack(spacing: DS.Spacing.card - 4) {
                    profileAvatarButton
                    identityBlock
                    Spacer()
                    profileCameraButton
                }
            }
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.vertical, DS.Spacing.card - 4)
        .dsCard()
    }

    private var profileAvatarButton: some View {
        Button {
            Haptics.light()
            openAvatarMenu(from: .profileAvatar)
        } label: {
            avatarView
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: avatarMenuPresented(for: .profileAvatar),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            avatarActionMenu(for: .me)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("更换我的头像")
    }

    private var profileCameraButton: some View {
        Button {
            Haptics.light()
            openAvatarMenu(from: .profileCamera)
        } label: {
            Image(systemName: "camera.fill")
                .font(DS.Typo.secondary.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(theme.accent.color, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .popover(
            isPresented: avatarMenuPresented(for: .profileCamera),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            avatarActionMenu(for: .me)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("更换头像")
    }

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.tight) {
            Text(store.session?.name ?? "未登录")
                .font(DS.Typo.button)
                .foregroundStyle(DS.Palette.textPrimary)
            if let partner = store.partner {
                Text("和 \(partner.name) 在一起")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text(store.connected ? "已连接 · hoo66.top" : (store.lastConnectionError ?? "未连接"))
                .font(DS.Typo.caption.weight(.medium))
                .foregroundStyle(store.connected ? DS.Palette.textSecondary : DS.Palette.red)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                openAvatarMenu(from: .dajuAvatar)
            }
            .popover(
                isPresented: avatarMenuPresented(for: .dajuAvatar),
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .top
            ) {
                avatarActionMenu(for: .daju)
                    .presentationCompactAdaptation(.popover)
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
                settingRowLabel(icon: "iphone.and.arrow.forward", title: "设备管理", subtitle: "手机与 iPad 同时登录")
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
                    .fixedSize(horizontal: false, vertical: true)
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
                        .fixedSize(horizontal: false, vertical: true)
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

    private func avatarActionMenu(for target: AvatarTarget) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target == .daju ? "更换大橘头像" : "更换头像")
                .font(DS.Typo.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if target == .daju {
                avatarMenuButton("使用默认大橘头像", systemImage: AccountPresentation.dajuIconName) {
                    avatarMenuSource = nil
                    useDefaultDajuAvatar()
                }
            }

            avatarMenuButton("从手机相册选择", systemImage: "photo.on.rectangle") {
                deferAvatarPresentation { showPhotoPicker = true }
            }
            avatarMenuButton("拍照", systemImage: "camera") {
                deferAvatarPresentation {
                    pendingCameraUpload = true
                    showCamera = true
                }
            }
            Divider().padding(.horizontal, 8)
            avatarMenuButton("取消", systemImage: "xmark") {
                avatarMenuSource = nil
            }
        }
        .padding(6)
        .frame(
            minWidth: 230,
            idealWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 250,
            maxWidth: 360)
    }

    private func avatarMenuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DS.Typo.body)
                .foregroundStyle(DS.Palette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

private enum AvatarTarget: Equatable {
    case me
    case daju
}

private enum AvatarMenuSource: Equatable {
    case profileAvatar
    case profileCamera
    case dajuAvatar

    var target: AvatarTarget {
        switch self {
        case .profileAvatar, .profileCamera: return .me
        case .dajuAvatar: return .daju
        }
    }
}
