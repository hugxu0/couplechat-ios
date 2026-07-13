import SwiftUI

struct AlbumManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String) async -> Bool
    @State private var title: String
    @State private var summary: String
    @State private var saving = false

    init(album: MomentAlbum, onSave: @escaping (String, String) async -> Bool) {
        self.onSave = onSave
        _title = State(initialValue: album.title)
        _summary = State(initialValue: album.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("相册名称", text: $title)
                TextField("共同相册简介", text: $summary, axis: .vertical)
                    .lineLimit(2...6)
            }
            .navigationTitle("编辑相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task {
                            saving = true
                            if await onSave(trimmedTitle, trimmedSummary) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || saving)
                }
            }
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }
}
