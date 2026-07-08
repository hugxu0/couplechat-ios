import SwiftUI

// MARK: - 鎸夋棩鏈熸煡鎵?
struct DateJumpSheet: View {
    let channel: ChatChannel
    var onJump: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeManager
    @State private var selectedDate = Date()
    @State private var didAppear = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("閫夋嫨鏃ユ湡", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(theme.accent.color)
                    .padding(.horizontal, 8)
                    .onChange(of: selectedDate) {
                        guard didAppear else { return }
                        Haptics.selection()
                        onJump(selectedDate)
                        dismiss()
                    }

                Button {
                    Haptics.light()
                    onJump(selectedDate)
                    dismiss()
                } label: {
                    Label("璺宠浆鍒板綋澶?, systemImage: "arrow.down.message.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(theme.accent.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 18)

                Spacer(minLength: 0)
            }
            .navigationTitle("鎸夋棩鏈熸煡鎵?)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("鍏抽棴") { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    didAppear = true
                }
            }
        }
    }
}

struct ChatSearchSheet: View {
    let channel: ChatChannel
    /// 鐐瑰嚮鏌愭潯缁撴灉鏃跺洖璋冨懡涓秷鎭紝鐢卞涓昏礋璐ｅ姞杞戒笂涓嬫枃骞舵粴鍔ㄥ畾浣?    var onJump: (ChatMessage) -> Void = { _ in }
    /// 闈?nil 鏃跺湪宸ュ叿鏍忔樉绀烘棩鍘嗗叆鍙ｏ紝鐢ㄤ簬鎸夋棩鏈熻烦杞?    var onJumpDate: ((Date) -> Void)? = nil

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var searching = false
    @State private var searched = false
    @State private var showDateJump = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    emptyState
                } else {
                    resultList
                }
            }
            .navigationTitle("鎼滅储鑱婂ぉ璁板綍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("鍏抽棴") { dismiss() }
                }
                if onJumpDate != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            showDateJump = true
                        } label: {
                            Image(systemName: "calendar")
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "鎼滅储娑堟伅鍐呭")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) {
                if query.isEmpty {
                    results = []
                    searched = false
                }
            }
            .sheet(isPresented: $showDateJump) {
                DateJumpSheet(channel: channel, onJump: { date in
                    onJumpDate?(date)
                    dismiss()
                })
                .presentationDetents([.medium, .large])
            }
        }
    }


    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if searching {
                ProgressView()
            } else if searched {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
                Text("娌℃湁鎵惧埌銆孿(query)銆嶇浉鍏崇殑娑堟伅")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                Text("杈撳叆鍏抽敭璇嶏紝鍥炶溅鎼滅储")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(results) { msg in
                    resultRow(msg)
                }
            } header: {
                Text("鍏?\(results.count) 鏉＄粨鏋?)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func resultRow(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(msg.senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.accent)
                Spacer()
                Text(Self.dateTime(msg.ts))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text(highlighted(msg.displayText))
                .font(.system(size: 15))
                .lineLimit(3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            onJump(msg)
            dismiss()
        }
    }

    /// 鍏抽敭璇嶅懡涓儴鍒嗘爣涓婚鑹插姞绮?    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = attributed.range(of: q, options: .caseInsensitive) else { return attributed }
        attributed[range].foregroundColor = DS.Palette.accent
        attributed[range].font = .system(size: 15, weight: .bold)
        return attributed
    }

    private static func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M鏈坉鏃?HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            let found = await store.searchMessages(q, channel: channel)
            await MainActor.run {
                searching = false
                searched = true
                withAnimation(DS.Anim.ease) {
                    // 鏈嶅姟绔寜鏃堕棿鍊掑簭杩斿洖锛岀洿鎺ュ睍绀猴紙鏈€鏂扮殑鍦ㄦ渶涓婇潰锛?                    results = found.sorted { $0.ts > $1.ts }
                }
            }
        }
    }
}
