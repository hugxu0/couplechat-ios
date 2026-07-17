import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var accounts: [Account] = []
    @State private var selected: Account?
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var accountsLoading = false
    @State private var accountsError: String?
    @FocusState private var pwFocused: Bool

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            VStack(spacing: DS.Spacing.compact) {
                CoupleEchoIndicator()
                Text("悄悄话")
                    .font(DS.Typo.display)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("只属于我们俩的小空间")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Group {
                if accounts.isEmpty {
                    VStack(spacing: 10) {
                        if accountsLoading || accountsError == nil {
                            ProgressView()
                            Text("正在加载账号…")
                                .font(DS.Typo.secondary)
                                .foregroundStyle(DS.Palette.textSecondary)
                        } else {
                            StatusBanner(
                                text: accountsError ?? "暂时没有读取到账号，请重试",
                                kind: .warning)
                            Button("重新加载") {
                                Task { await loadAccounts() }
                            }
                            .font(DS.Typo.button)
                            .foregroundStyle(DS.Palette.accent)
                        }
                    }
                    .frame(minHeight: 102)
                } else {
                    HStack(spacing: 14) {
                        ForEach(accounts, id: \.username) { acc in
                            Button {
                                Haptics.selection()
                                DS.Anim.withMotion(DS.Anim.springFast) { selected = acc }
                                pwFocused = true
                            } label: {
                                VStack(spacing: 6) {
                                    AvatarBadge(
                                        url: AccountPresentation.mediaURL(acc.avatar),
                                        fallbackEmoji: AccountPresentation.avatarText(acc.avatar, for: acc.username),
                                        size: 72)
                                        .clipShape(Circle())
                                        .overlay {
                                            Circle().strokeBorder(
                                                selected == acc ? DS.Palette.accent : .clear, lineWidth: 3)
                                        }
                                    Text(acc.name)
                                        .font(DS.Typo.button)
                                        .foregroundStyle(
                                            selected == acc ? DS.Palette.accent : DS.Palette.textPrimary)
                                }
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("选择 \(acc.name)")
                            .accessibilityAddTraits(selected == acc ? .isSelected : [])
                        }
                    }
                }
            }

            VStack(spacing: 14) {
                SecureField("密码", text: $password)
                    .focused($pwFocused)
                    .textContentType(.password)
                    .font(DS.Typo.body)
                    .padding(.horizontal, DS.Spacing.fieldHorizontal)
                    .padding(.vertical, DS.Spacing.fieldVertical)
                    .background(DS.Palette.fieldSurface)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .stroke(DS.Palette.hairline, lineWidth: 0.5)
                    }
                    .onSubmit(submit)

                if let error {
                    StatusBanner(text: error, kind: .error)
                }

                AppPrimaryButton(
                    title: "进入",
                    busy: busy,
                    enabled: selected != nil && !password.isEmpty,
                    action: submit
                )

            }
            .padding(.horizontal, 34)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppPageBackground())
        .task {
            await loadAccounts()
        }
    }

    private func loadAccounts() async {
        guard !accountsLoading else { return }
        accountsLoading = true
        accountsError = nil
        defer { accountsLoading = false }

        if !store.auth.accounts.isEmpty {
            accounts = store.auth.accounts
            return
        }
        for attempt in 0..<3 {
            let fetched = await store.auth.fetchAccounts()
            guard fetched.isEmpty else {
                accounts = fetched
                return
            }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        accountsError = "账号加载失败，请检查网络后重试"
    }

    private func submit() {
        guard let selected, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await store.login(username: selected.username, password: password)
                Haptics.light()
            } catch {
                self.error = error.localizedDescription
                Haptics.medium()
            }
            busy = false
        }
    }
}
