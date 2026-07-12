import SwiftUI

struct BarkSettingsSheet: View {
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
                        Text(errorText).font(DS.Typo.caption).foregroundStyle(DS.Palette.red)
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
            let ok: Bool
            if let token = store.auth.session?.token {
                ok = await store.shared.saveBarkKey(enabled ? key : nil, token: token)
            } else {
                ok = false
            }
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
