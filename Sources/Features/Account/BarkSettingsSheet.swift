import SwiftUI

struct BarkSettingsSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var enabled = false
    @State private var keyInput = ""
    @State private var busy = false
    @State private var errorText: String?
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
            removeLegacySecrets(for: snapshot.username, defaults: defaults)
            busy = false
            saveTask = nil
            Haptics.medium()
            dismiss()
        }
    }

    private func restoreSavedState() {
        guard let username = store.auth.session?.username else { return }
        let defaults = UserDefaults.standard
        if let saved = Keychain.loadBarkKey(for: username) {
            keyInput = saved
            removeLegacySecrets(for: username, defaults: defaults)
        } else if let legacy = legacySecret(for: username, defaults: defaults),
                  !legacy.isEmpty,
                  Keychain.saveBarkKey(legacy, for: username) {
            keyInput = legacy
            removeLegacySecrets(for: username, defaults: defaults)
        } else {
            keyInput = ""
        }
        let accountEnabledKey = enabledStorageKey(username)
        if defaults.object(forKey: accountEnabledKey) != nil {
            enabled = defaults.bool(forKey: accountEnabledKey)
        } else if defaults.object(forKey: "bark.enabled") != nil {
            enabled = defaults.bool(forKey: "bark.enabled")
            defaults.set(enabled, forKey: accountEnabledKey)
            defaults.removeObject(forKey: "bark.enabled")
        } else {
            enabled = false
        }
    }

    private func enabledStorageKey(_ username: String) -> String {
        "bark.enabled.\(username)"
    }

    private func legacySecretStorageKey(_ username: String) -> String {
        "bark.key.\(username)"
    }

    private func legacySecret(for username: String, defaults: UserDefaults) -> String? {
        defaults.string(forKey: legacySecretStorageKey(username))
            ?? defaults.string(forKey: "bark.key")
    }

    private func removeLegacySecrets(for username: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: legacySecretStorageKey(username))
        defaults.removeObject(forKey: "bark.key")
    }
}
