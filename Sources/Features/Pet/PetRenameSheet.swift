import SwiftUI

struct PetRenameSheet: View {
    let currentName: String
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(currentName: String, onSave: @escaping (String) async -> Bool) {
        self.currentName = currentName
        self.onSave = onSave
        _name = State(initialValue: currentName)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("这个名字会同步到你们所有登录设备。")
                    .font(DS.Typo.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)

                TextField("大橘的名字", text: $name)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .padding(14)
                    .background(DS.Palette.innerSurface)
                    .clipShape(RoundedRectangle(
                        cornerRadius: DS.Radius.control, style: .continuous))
                    .onSubmit(save)

                Text("\(trimmed.count)/24")
                    .font(DS.Typo.caption.monospacedDigit())
                    .foregroundStyle(trimmed.count > 24 ? DS.Palette.red : DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Spacer()
            }
            .padding(DS.Spacing.page)
            .background(AppPageBackground())
            .navigationTitle("给大橘改名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存", action: save)
                        .disabled(!canSave || isSaving)
                }
            }
        }
        .presentationDetents([.height(280)])
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed.count <= 24 && trimmed != currentName
    }

    private func save() {
        guard canSave, !isSaving else { return }
        isSaving = true
        Task {
            let succeeded = await onSave(trimmed)
            isSaving = false
            if succeeded { dismiss() }
        }
    }
}
