import SwiftUI

// 登录页：从 /api/accounts 拉两个账号 → 选人 → 输密码。

struct LoginView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var accounts: [Account] = []
    @State private var selected: Account?
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var pwFocused: Bool

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            VStack(spacing: 8) {
                Text("💗").font(.system(size: 52))
                Text("悄悄话")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("只属于我们俩的小空间")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            // 选账号
            HStack(spacing: 14) {
                ForEach(accounts, id: \.username) { acc in
                    Button {
                        Haptics.selection()
                        withAnimation(DS.Anim.springFast) { selected = acc }
                        pwFocused = true
                    } label: {
                        VStack(spacing: 6) {
                            Text(acc.username == "xu" ? "🐶" : "🐰")
                                .font(.system(size: 36))
                                .frame(width: 72, height: 72)
                                .background(Color.white.opacity(0.9))
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(
                                        selected == acc ? DS.Palette.accent : .clear, lineWidth: 3)
                                }
                            Text(acc.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(selected == acc ? DS.Palette.accent : DS.Palette.textPrimary)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            // 密码 + 登录
            VStack(spacing: 14) {
                SecureField("密码", text: $password)
                    .focused($pwFocused)
                    .textContentType(.password)
                    .font(.system(size: 16))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
                    .onSubmit(submit)

                if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                Button(action: submit) {
                    Group {
                        if busy {
                            ProgressView().tint(.white)
                        } else {
                            Text("进入").font(.system(size: 17, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(DS.Palette.accentGradient)
                    .clipShape(Capsule())
                    .opacity(selected == nil || password.isEmpty ? 0.5 : 1)
                }
                .buttonStyle(PressableStyle())
                .disabled(selected == nil || password.isEmpty || busy)
            }
            .padding(.horizontal, 34)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bgGradient.ignoresSafeArea())
        .task {
            accounts = await store.fetchAccounts()
        }
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
