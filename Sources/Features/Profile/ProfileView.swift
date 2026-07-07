import SwiftUI

// 我的页：身份卡 + 外观（主题色/深浅模式）+ 日期设置 + 离线通知 + 退出登录。

struct ProfileView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager

    @State private var showDateEditor = false
    @State private var showBarkSheet = false
    @State private var showLogoutConfirm = false

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
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDateEditor) {
                DateEditorSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showBarkSheet) {
                BarkSettingsSheet()
                    .presentationDetents([.medium])
            }
            .confirmationDialog("确定退出登录吗？", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Haptics.medium()
                    store.logout()
                }
            }
        }
    }

    // MARK: - 身份卡
    private var header: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Text(AccountPresentation.avatar(for: store.session?.username ?? "xu"))
                    .font(.system(size: 46))
                    .frame(width: 92, height: 92)
                    .background(theme.accent.color.opacity(0.12))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(theme.accent.color.opacity(0.35), lineWidth: 2))
                // 连接状态小圆点
                Circle()
                    .fill(store.connected ? DS.Palette.green : .red)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 3))
            }
            VStack(spacing: 4) {
                Text(store.session?.name ?? "未登录")
                    .font(.system(size: 22, weight: .bold))
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
            }
            Text(store.connected ? "已连接 · hoo66.top" : (store.lastConnectionError ?? "未连接"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(store.connected ? DS.Palette.textSecondary : .red)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(DS.Palette.innerSurface)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .dsCard()
    }

    // MARK: - 设置项
    private var settingsCard: some View {
        VStack(spacing: 0) {
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
