import SwiftUI

struct AttachmentManagerView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var app: AppState
    @State private var channel: ChatChannel = .couple
    @State private var items: [ChatMessage] = []

    var body: some View {
        List {
            Picker("频道", selection: $channel) {
                Text("两人").tag(ChatChannel.couple)
                Text("大橘").tag(ChatChannel.ai)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if items.isEmpty {
                AppEmptyState("暂无媒体或文件", systemImage: "folder")
            } else {
                Section("最近 \(items.count) 项") {
                    ForEach(items) { item in
                        Button {
                            if let url = item.mediaURL {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: item.type))
                                    .font(DS.Typo.button)
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(tint(for: item.type), in: RoundedRectangle(cornerRadius: DS.Radius.chip - 1, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(for: item))
                                        .font(DS.Typo.body.weight(.medium))
                                        .foregroundStyle(DS.Palette.textPrimary)
                                        .lineLimit(1)
                                    Text(dateTime(item.ts))
                                        .font(DS.Typo.caption)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(DS.Typo.micro.weight(.semibold))
                                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.6))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(item.mediaURL == nil)
                    }
                }
            }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.pushSubpage() }
        .onDisappear { app.popSubpage() }
        .task(id: channel) {
            items = await store.messageStore.mediaMessages(
                for: channel, includeFiles: true, limit: 300)
        }
    }

    private func icon(for type: String) -> String {
        switch type {
        case "image": return "photo"
        case "video": return "play.rectangle"
        default: return "doc"
        }
    }

    private func tint(for type: String) -> Color {
        switch type {
        case "image": return DS.Palette.pink
        case "video": return DS.Palette.purple
        default: return DS.Palette.blue
        }
    }

    private func title(for item: ChatMessage) -> String {
        let text = item.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && !text.hasPrefix("[") { return text }
        if let name = item.mediaURL?.lastPathComponent, !name.isEmpty { return name }
        switch item.type {
        case "image": return "图片"
        case "video": return "视频"
        default: return "文件"
        }
    }

    private func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }
}
