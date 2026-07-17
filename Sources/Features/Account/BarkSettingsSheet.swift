import SwiftUI

struct BarkSettingsSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = false
    @State private var keyInput = ""
    @State private var busy = false
    @State private var testing = false
    @State private var errorText: String?
    @State private var statusText: String?
    @State private var savedKey = ""
    @State private var saveTask: Task<Void, Never>?

    private struct SaveSnapshot {
        let username: String
        let token: String
        let enabled: Bool
        let key: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("离线通知", isOn: $enabled)
                } footer: {
                    Text("只控制这台设备。修改后点右上角“保存”；同一账号的手机和平板可以分别使用自己的 Bark key。")
                }
                Section("Bark 设备 Key") {
                    TextField("从 Bark App 复制", text: $keyInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let errorText {
                        Text(errorText).font(DS.Typo.caption).foregroundStyle(DS.Palette.red)
                    }
                    if let statusText {
                        Label(statusText, systemImage: "checkmark.circle.fill")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.green)
                    }
                }
                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Label("发送测试通知", systemImage: "paperplane.fill")
                            Spacer()
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!enabled || testing || busy || savedKey.isEmpty || savedKey != trimmedKey)
                } footer: {
                    Text(savedKey == trimmedKey ? "测试通知只发送到这台设备。" : "先保存当前 Key，再发送测试通知。")
                }
            }
            .disabled(busy)
            .navigationTitle("离线通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("保存") { apply() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .onAppear { restoreSavedState() }
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
            }
            .interactiveDismissDisabled(busy)
        }
    }

    private func apply() {
        guard !busy, let session = store.auth.session else {
            errorText = "登录状态已失效，请重新登录"
            return
        }
        let snapshot = SaveSnapshot(
            username: session.username,
            token: session.token,
            enabled: enabled,
            key: keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
        if snapshot.enabled && snapshot.key.isEmpty {
            errorText = "请先填入 Bark 设备 key"
            return
        }
        busy = true
        errorText = nil
        statusText = nil
        saveTask = Task { @MainActor in
            let ok = await store.shared.saveBarkKey(
                snapshot.enabled ? snapshot.key : nil,
                token: snapshot.token)
            guard !Task.isCancelled else { return }
            guard store.auth.session?.username == snapshot.username,
                  store.auth.session?.token == snapshot.token else {
                busy = false
                saveTask = nil
                errorText = "账号已变更，请重新打开设置"
                return
            }
            guard ok else {
                busy = false
                saveTask = nil
                errorText = "保存失败，请检查网络后重试"
                return
            }

            let secretStored: Bool
            if snapshot.enabled {
                secretStored = Keychain.saveBarkKey(snapshot.key, for: snapshot.username)
            } else {
                Keychain.deleteBarkKey(for: snapshot.username)
                secretStored = true
            }
            guard secretStored else {
                busy = false
                saveTask = nil
                errorText = "系统安全存储暂不可用，请稍后重试"
                return
            }

            let defaults = UserDefaults.standard
            defaults.set(snapshot.enabled, forKey: enabledStorageKey(snapshot.username))
            busy = false
            saveTask = nil
            savedKey = snapshot.enabled ? snapshot.key : ""
            statusText = snapshot.enabled ? "已保存，可以发送测试通知" : "已关闭这台设备的通知"
            Haptics.medium()
        }
    }

    private func restoreSavedState() {
        guard let username = store.auth.session?.username else { return }
        let defaults = UserDefaults.standard
        if let saved = Keychain.loadBarkKey(for: username) {
            keyInput = saved
            savedKey = saved
        } else {
            keyInput = ""
            savedKey = ""
        }
        let accountEnabledKey = enabledStorageKey(username)
        enabled = defaults.bool(forKey: accountEnabledKey)
    }

    private var trimmedKey: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func testConnection() {
        guard !testing, let token = store.auth.session?.token else { return }
        testing = true
        errorText = nil
        statusText = nil
        Task { @MainActor in
            let ok = await store.shared.testBark(token: token)
            testing = false
            if ok {
                statusText = "测试通知已发送"
                Haptics.medium()
            } else {
                errorText = "测试发送失败，请检查 Bark Key"
            }
        }
    }

    private func enabledStorageKey(_ username: String) -> String {
        "bark.enabled.\(username)"
    }

}
