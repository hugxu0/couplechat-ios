import SwiftUI

struct CouplePairingView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var mode: PairingMode = .choose
    @State private var spaceName = ""
    @State private var inviteCode = ""
    @State private var createdInvite: CoupleInvite?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.section) {
                    pairingHero
                    content
                    Button("退出当前账号", role: .destructive) { store.logout() }
                        .font(DS.Typo.secondary)
                        .disabled(busy)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, DS.Spacing.page)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .background(AppPageBackground())
            .navigationTitle("完成配对")
            .navigationBarTitleDisplayMode(.inline)
            .task { await store.refreshPairingStatus() }
        }
    }

    private var pairingHero: some View {
        VStack(spacing: DS.Spacing.gap) {
            ZStack {
                Circle()
                    .fill(DS.Palette.accentGradient)
                    .frame(width: 92, height: 92)
                Image(systemName: "person.2.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("把两台设备连到同一个空间")
                .font(DS.Typo.pageTitle)
                .foregroundStyle(DS.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("一人创建并分享邀请码，另一人输入邀请码加入。相册、计划、大橘和 Memory 都会按这个空间同步。")
                .font(DS.Typo.secondary)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .choose:
            VStack(spacing: DS.Spacing.gap) {
                PairingChoiceCard(
                    title: "创建两人空间",
                    detail: "生成一个 7 天有效的邀请码，发给你的另一半",
                    systemImage: "sparkles") {
                        mode = .create
                    }
                PairingChoiceCard(
                    title: "输入邀请码加入",
                    detail: "使用对方发来的邀请码进入同一个空间",
                    systemImage: "link") {
                        mode = .join
                    }
            }
        case .create:
            createCard
        case .join:
            joinCard
        }
    }

    private var createCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: DS.Spacing.gap) {
                AppSectionHeader(
                    title: createdInvite == nil ? "给空间起个名字" : "邀请码已生成",
                    subtitle: createdInvite == nil ? "以后可以继续修改，不填也可以" : "把它发给另一半后即可进入")
                if let invite = createdInvite {
                    Text(invite.code)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .tracking(4)
                        .foregroundStyle(DS.Palette.accent)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(DS.Palette.innerSurface)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
                        .accessibilityLabel("配对邀请码 \(invite.code)")
                    Text("有效期至 \(expirationText(invite.expiresAt))")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                    ShareLink(item: "来和我加入悄悄话：配对邀请码 \(invite.code)") {
                        Label("分享邀请码", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)
                    AppPrimaryButton(title: "进入我们的空间", action: {
                        Task { await store.completePairing() }
                    })
                } else {
                    pairingField("例如：小旭和小偲", text: $spaceName)
                    errorBanner
                    AppPrimaryButton(title: "创建并生成邀请码", busy: busy, action: createSpace)
                    backButton
                }
            }
        }
    }

    private var joinCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: DS.Spacing.gap) {
                AppSectionHeader(title: "输入邀请码", subtitle: "邀请码不区分大小写")
                pairingField("8 位邀请码", text: $inviteCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: inviteCode) {
                        inviteCode = String(inviteCode.uppercased()
                            .filter { $0.isLetter || $0.isNumber }
                            .prefix(32))
                    }
                errorBanner
                AppPrimaryButton(
                    title: "加入两人空间",
                    busy: busy,
                    enabled: inviteCode.count >= 6,
                    action: joinSpace)
                backButton
            }
        }
    }

    private func pairingField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(DS.Typo.body)
            .padding(.horizontal, DS.Spacing.fieldHorizontal)
            .padding(.vertical, DS.Spacing.fieldVertical)
            .background(DS.Palette.fieldSurface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(DS.Palette.hairline, lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorText { StatusBanner(text: errorText, kind: .error) }
    }

    private var backButton: some View {
        Button("返回选择") {
            errorText = nil
            mode = .choose
        }
        .font(DS.Typo.secondary)
        .frame(maxWidth: .infinity)
        .disabled(busy)
    }

    private func createSpace() {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            do {
                createdInvite = try await store.createCouple(name: spaceName).invite
                Haptics.light()
            } catch {
                errorText = error.localizedDescription
                Haptics.medium()
            }
            busy = false
        }
    }

    private func joinSpace() {
        guard inviteCode.count >= 6, !busy else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await store.joinCouple(code: inviteCode)
                Haptics.light()
            } catch {
                errorText = error.localizedDescription
                Haptics.medium()
            }
            busy = false
        }
    }

    private func expirationText(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private enum PairingMode {
    case choose
    case create
    case join
}

private struct PairingChoiceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AppCard {
                HStack(spacing: DS.Spacing.gap) {
                    Image(systemName: systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(DS.Palette.accent)
                        .frame(width: 48, height: 48)
                        .background(DS.Palette.accent.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(DS.Typo.cardTitle)
                        Text(detail)
                            .font(DS.Typo.secondary)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .foregroundStyle(DS.Palette.textPrimary)
            }
        }
        .buttonStyle(PressableStyle())
    }
}
