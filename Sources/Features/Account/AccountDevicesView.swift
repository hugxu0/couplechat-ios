import SwiftUI

struct AccountDevicesView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var devices: [AccountDevice] = []
    @State private var invite: CoupleInvite?
    @State private var loading = true
    @State private var generatingInvite = false
    @State private var errorText: String?
    @State private var deviceToRevoke: AccountDevice?
    private let repository = DeviceSessionRepository()

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.section) {
                inviteCard
                deviceSection
            }
            .frame(maxWidth: 720)
            .padding(DS.Spacing.page)
            .frame(maxWidth: .infinity)
        }
        .background(AppPageBackground())
        .navigationTitle("配对与设备")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDevices() }
        .refreshable { await loadDevices() }
        .confirmationDialog(
            "让这台设备退出登录？",
            isPresented: Binding(
                get: { deviceToRevoke != nil },
                set: { if !$0 { deviceToRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("移除设备", role: .destructive) { revokeSelectedDevice() }
            Button("取消", role: .cancel) { deviceToRevoke = nil }
        } message: {
            Text("移除后，该设备的会话和 Bark 推送都会立即失效。")
        }
    }

    private var inviteCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: DS.Spacing.gap) {
                AppSectionHeader(
                    title: "配对邀请码",
                    subtitle: "只有新账号加入当前两人空间时才需要")
                if let invite {
                    HStack(alignment: .firstTextBaseline) {
                        Text(invite.code)
                            .font(.system(.title, design: .monospaced).weight(.bold))
                            .tracking(3)
                            .foregroundStyle(DS.Palette.accent)
                            .textSelection(.enabled)
                        Spacer()
                        ShareLink(item: "来和我加入悄悄话：配对邀请码 \(invite.code)") {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3.weight(.semibold))
                        }
                        .accessibilityLabel("分享邀请码")
                    }
                    Text("有效期至 \(dateText(invite.expiresAt))。再次生成会让旧邀请码失效。")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                if let errorText { StatusBanner(text: errorText, kind: .error) }
                AppPrimaryButton(
                    title: invite == nil ? "生成邀请码" : "重新生成邀请码",
                    busy: generatingInvite,
                    action: generateInvite)
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            AppSectionHeader(
                title: "已登录设备",
                subtitle: "手机和平板可以同时在线，消息、计划和共同内容会同步")
            if loading && devices.isEmpty {
                AppCard {
                    HStack(spacing: DS.Spacing.gap) {
                        ProgressView()
                        Text("正在读取设备…")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            } else if devices.isEmpty {
                AppEmptyState("没有可用设备", systemImage: "iphone.slash")
                    .frame(minHeight: 180)
            } else {
                ForEach(devices) { device in
                    deviceCard(device)
                }
            }
        }
    }

    private func deviceCard(_ device: AccountDevice) -> some View {
        let isCurrent = device.id == store.session?.deviceId
        return AppCard {
            HStack(spacing: DS.Spacing.gap) {
                Image(systemName: device.platform == "ipados" ? "ipad" : "iphone")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isCurrent ? DS.Palette.accent : DS.Palette.textSecondary)
                    .frame(width: 48, height: 48)
                    .background(DS.Palette.innerSurface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.deviceName.isEmpty ? fallbackName(device) : device.deviceName)
                            .font(DS.Typo.cardTitle)
                        if isCurrent {
                            Text("当前")
                                .font(DS.Typo.micro)
                                .foregroundStyle(DS.Palette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(DS.Palette.accent.opacity(0.11))
                                .clipShape(Capsule())
                        }
                    }
                    Text("悄悄话 \(device.appVersion.isEmpty ? "未知版本" : device.appVersion) · \(dateText(device.lastSeenAt))")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                    Label(
                        device.barkEnabled ? "Bark 已启用" : "Bark 未启用",
                        systemImage: device.barkEnabled ? "bell.badge.fill" : "bell.slash")
                        .font(DS.Typo.caption)
                        .foregroundStyle(device.barkEnabled ? DS.Palette.green : DS.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                if !isCurrent {
                    Button(role: .destructive) { deviceToRevoke = device } label: {
                        Image(systemName: "trash")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("移除 \(device.deviceName)设备")
                }
            }
        }
    }

    private func loadDevices() async {
        guard let token = store.session?.token else { return }
        loading = true
        do {
            devices = try await repository.list(token: token)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func generateInvite() {
        guard let token = store.session?.token, !generatingInvite else { return }
        generatingInvite = true
        errorText = nil
        Task {
            do {
                invite = try await store.coupleOnboarding.newInvite(token: token)
                Haptics.light()
            } catch {
                errorText = error.localizedDescription
                Haptics.medium()
            }
            generatingInvite = false
        }
    }

    private func revokeSelectedDevice() {
        guard let target = deviceToRevoke,
              let token = store.session?.token else { return }
        deviceToRevoke = nil
        Task {
            do {
                try await repository.revoke(id: target.id, token: token)
                devices.removeAll { $0.id == target.id }
                Haptics.light()
            } catch {
                errorText = error.localizedDescription
                Haptics.medium()
            }
        }
    }

    private func fallbackName(_ device: AccountDevice) -> String {
        device.platform == "ipados" ? "iPad" : "iPhone"
    }

    private func dateText(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}
