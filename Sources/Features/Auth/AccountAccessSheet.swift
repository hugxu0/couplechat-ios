import SwiftUI

struct AccountAccessSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AccountAccessMode = .login
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $mode) {
                        ForEach(AccountAccessMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { errorText = nil }
                }

                Section {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .onChange(of: username) {
                            username = String(username.lowercased().prefix(24))
                        }
                    if mode == .register {
                        TextField("显示名称", text: $displayName)
                            .textContentType(.name)
                    }
                    SecureField("密码", text: $password)
                        .textContentType(mode == .register ? .newPassword : .password)
                    if mode == .register {
                        SecureField("再次输入密码", text: $confirmation)
                            .textContentType(.newPassword)
                    }
                } header: {
                    Text(mode == .login ? "账号登录" : "创建账号")
                } footer: {
                    if mode == .register {
                        Text("用户名使用 3–24 位小写字母、数字或下划线；密码至少 8 位。注册后还需要创建两人空间或输入邀请码。")
                    }
                }

                if let errorText {
                    Section { StatusBanner(text: errorText, kind: .error) }
                        .listRowBackground(Color.clear)
                }

                Section {
                    AppPrimaryButton(
                        title: mode == .login ? "登录" : "注册并继续",
                        busy: busy,
                        enabled: formIsValid,
                        action: submit)
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .background(AppPageBackground())
            .navigationTitle(mode == .login ? "其他账号" : "创建账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(busy)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var formIsValid: Bool {
        switch mode {
        case .login:
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
        case .register:
            return username.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) != nil
                && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && password.count >= 8
                && password == confirmation
        }
    }

    private func submit() {
        guard formIsValid, !busy else { return }
        busy = true
        errorText = nil
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch mode {
                case .login:
                    try await store.login(username: normalizedUsername, password: password)
                case .register:
                    try await store.register(
                        username: normalizedUsername,
                        displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: password)
                }
                Haptics.light()
                dismiss()
            } catch {
                errorText = error.localizedDescription
                Haptics.medium()
            }
            busy = false
        }
    }
}

private enum AccountAccessMode: String, CaseIterable, Identifiable {
    case login
    case register

    var id: String { rawValue }
    var title: String { self == .login ? "登录" : "注册" }
}
