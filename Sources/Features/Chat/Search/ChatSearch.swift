import SwiftUI

struct DateJumpSheet: View {
    let channel: ChatChannel
    var onJump: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeManager
    @State private var selectedDate = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("选择日期", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .tint(theme.accent.color)
                    .padding(.horizontal, 8)

                Button {
                    Haptics.light()
                    onJump(selectedDate)
                    dismiss()
                } label: {
                    Label("跳转到当天", systemImage: "arrow.down.message.fill")
                        .font(DS.Typo.button)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(theme.accent.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 18)

                Spacer(minLength: 0)
            }
            .navigationTitle("按日期查找")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
struct ChatSearchSheet: View {
    let channel: ChatChannel
    /// 点击某条结果时回调命中消息，由宿主负责加载上下文并滚动定位
    var onJump: (ChatMessage) -> Void = { _ in }
    /// 非 nil 时在工具栏显示日历入口，用于按日期跳转
    var onJumpDate: ((Date) -> Void)? = nil

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ChatMessage] = []
    @State private var searching = false
    @State private var loadingMore = false
    @State private var searched = false
    @State private var nextCursor: MessageSearchCursor?
    @State private var hasMore = false
    @State private var searchToken = UUID()
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
            .navigationTitle("搜索聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索消息内容")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) {
                searchToken = UUID()
                searching = false
                loadingMore = false
                results = []
                searched = false
                nextCursor = nil
                hasMore = false
            }
            .sheet(isPresented: $showDateJump) {
                DateJumpSheet(channel: channel, onJump: { date in
                    showDateJump = false
                    onJumpDate?(date)
                    DispatchQueue.main.async {
                        dismiss()
                    }
                })
                .presentationDetents([.medium, .large])
                .presentationSizing(.form)
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
                Text("没有找到「\(query)」相关的消息")
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                Text("输入关键词，回车搜索")
                    .font(DS.Typo.body)
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
                Text(hasMore ? "已显示 \(results.count) 条结果" : "共 \(results.count) 条结果")
            }

            if hasMore || loadingMore {
                Section {
                    Button {
                        loadMore()
                    } label: {
                        HStack {
                            Spacer()
                            if loadingMore {
                                ProgressView()
                            } else {
                                Label("加载更多结果", systemImage: "arrow.down.circle")
                            }
                            Spacer()
                        }
                    }
                    .disabled(loadingMore)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func resultRow(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(msg.senderName)
                    .font(DS.Typo.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.accent)
                Spacer()
                Text(Self.dateTime(msg.ts))
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text(highlighted(msg.displayText))
                .font(DS.Typo.body)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            onJump(msg)
            dismiss()
        }
    }

    /// 关键词命中部分标主题色加粗
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = attributed.range(of: q, options: .caseInsensitive) else { return attributed }
        attributed[range].foregroundColor = DS.Palette.accent
        attributed[range].font = .body.bold()
        return attributed
    }

    private static func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let token = UUID()
        searchToken = token
        searching = true
        searched = false
        loadingMore = false
        results = []
        nextCursor = nil
        hasMore = false
        Task {
            let page = await store.searchMessages(q, channel: channel)
            await MainActor.run {
                guard searchToken == token,
                      query.trimmingCharacters(in: .whitespaces) == q else { return }
                searching = false
                searched = true
                withAnimation(DS.Anim.ease) {
                    // 服务端按时间倒序返回，直接展示（最新的在最上面）
                    results = page.messages.sorted {
                        $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts
                    }
                    nextCursor = page.nextCursor
                    hasMore = page.hasMore
                }
            }
        }
    }

    private func loadMore() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !loadingMore, hasMore, let cursor = nextCursor else { return }
        let token = searchToken
        loadingMore = true
        Task {
            let page = await store.searchMessages(q, channel: channel, cursor: cursor)
            await MainActor.run {
                guard searchToken == token,
                      query.trimmingCharacters(in: .whitespaces) == q else { return }
                loadingMore = false
                var seen = Set(results.map(\.id))
                results.append(contentsOf: page.messages.filter { seen.insert($0.id).inserted })
                results.sort {
                    $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts
                }
                nextCursor = page.nextCursor
                hasMore = page.hasMore
            }
        }
    }
}
