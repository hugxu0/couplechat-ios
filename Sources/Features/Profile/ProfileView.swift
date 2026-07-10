import SwiftUI
import PhotosUI

// 我的页：身份卡 + 外观（主题色/深浅模式）+ 日期设置 + 离线通知 + 退出登录。

struct ProfileView: View {
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
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
                CameraPicker(image: $customAvatar)
                    .ignoresSafeArea()
            }
            .confirmationDialog("更换头像", isPresented: $showAvatarActionSheet, titleVisibility: .visible) {
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

    // MARK: - 身份横栏
    private var header: some View {
        HStack(spacing: 14) {
            avatarView
                .onTapGesture {
                    Haptics.light()
                    openAvatarPicker(for: .me)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(store.session?.name ?? "未登录")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Palette.textPrimary)
                if let partner = store.partner {
                    HStack(spacing: 4) {
                        Text("和")
                        Text(partner.name).fontWeight(.semibold).foregroundStyle(theme.accent.color)
                        Text("在一起")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textSecondary)
                }
                Text(store.connected ? "已连接 · hoo66.top" : (store.lastConnectionError ?? "未连接"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.connected ? DS.Palette.textSecondary : .red)
            }

            Spacer()

            Button {
                Haptics.light()
                openAvatarPicker(for: .me)
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(theme.accent.color, in: Circle())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.vertical, 14)
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
                        .font(.system(size: 28))
                        .frame(width: 52, height: 52)
                        .background(theme.accent.color.opacity(0.12))
                }
            } else {
                Text(myEmoji)
                    .font(.system(size: 28))
                    .frame(width: 52, height: 52)
                    .background(theme.accent.color.opacity(0.12))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(theme.accent.color.opacity(0.35), lineWidth: 2))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(store.connected ? DS.Palette.green : .red)
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
                ThemeStyleView()
            } label: {
                settingRowLabel(icon: "paintpalette", title: "主题样式", subtitle: "主题色 · 深色模式 · 聊天壁纸")
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
                StorageView()
            } label: {
                settingRowLabel(icon: "internaldrive", title: "存储空间", subtitle: "同步聊天记录 · 缓存管理")
            }
            .buttonStyle(PressableStyle())
            divider
            NavigationLink {
                FavoriteMediaView()
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .dsCard(radius: DS.Radius.tile + 4)
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
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(theme.accent.color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, DS.Spacing.card)
        .padding(.vertical, 12)
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
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, DS.Spacing.card)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private enum AvatarTarget: Equatable {
    case me
    case daju
}

// MARK: - 系统相机桥接（UIKit → SwiftUI）

private struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let edited = info[.editedImage] as? UIImage {
                parent.image = edited
            } else if let original = info[.originalImage] as? UIImage {
                parent.image = original
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Bark 离线通知设置

private struct BarkSettingsSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("bark.key") private var savedKey = ""
    @AppStorage("bark.enabled") private var enabled = false
    @State private var keyInput = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("离线通知", isOn: $enabled)
                        .onChange(of: enabled) { apply() }
                } footer: {
                    Text("开启后，对方在你不在线时发消息会通过 Bark 推送到这台设备。需要先安装 Bark App 并填入设备 key。")
                }
                Section("Bark 设备 Key") {
                    TextField("从 Bark App 复制", text: $keyInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("离线通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("保存") { apply(force: true) }
                            .fontWeight(.semibold)
                    }
                }
            }
            .onAppear { keyInput = savedKey }
        }
    }

    private func apply(force: Bool = false) {
        let key = keyInput.trimmingCharacters(in: .whitespaces)
        if enabled && key.isEmpty {
            if force { errorText = "请先填入 Bark 设备 key" }
            return
        }
        busy = true
        errorText = nil
        Task {
            let ok = await store.saveBarkKey(enabled ? key : nil)
            await MainActor.run {
                busy = false
                if ok {
                    savedKey = key
                    Haptics.medium()
                    if force { dismiss() }
                } else {
                    errorText = "保存失败，请检查网络后重试"
                }
            }
        }
    }
}
