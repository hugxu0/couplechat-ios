import SwiftUI

struct AIMemoryControlCenterView: View {
    @EnvironmentObject private var store: ChatStore

    @State private var primaryFilter = AIMemoryPrimaryFilter.all
    @State private var dajuKind = AIMemoryKind.instruction
    @State private var layer: AIMemoryLayer?
    @State private var searchText = ""
    @State private var snapshot = AIMemorySnapshot(items: [], stats: .empty)
    @State private var isLoading = false
    @State private var refreshingScope: AIMemoryScopeFilter?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                AIMemoryOverviewCard(
                    stats: snapshot.stats,
                    isRefreshing: refreshingScope != nil)
            }
            scopeSection
            categorySection
            memoriesSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("大橘与记忆")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索大橘记住的内容")
        .refreshable { await load() }
        .toolbar { refreshMenu }
        .task(id: LoadKey(
            primaryFilter: primaryFilter, dajuKind: dajuKind,
            layer: layer, query: searchText)) {
            if !searchText.isEmpty {
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
            guard note.persistentSyncIncludes(["memory"]) else { return }
            Task { await load() }
        }
    }

    private var scopeSection: some View {
        Section {
            Picker("记忆范围", selection: $primaryFilter) {
                ForEach(AIMemoryPrimaryFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var categorySection: some View {
        Section("分类") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if primaryFilter == .daju {
                        AIMemoryKindChip(kind: .instruction, isSelected: dajuKind == .instruction) {
                            dajuKind = .instruction
                        }
                        AIMemoryKindChip(kind: .observation, isSelected: dajuKind == .observation) {
                            dajuKind = .observation
                        }
                    } else {
                        AIMemoryLayerChip(layer: nil, isSelected: layer == nil) { layer = nil }
                        ForEach(AIMemoryLayer.allCases) { candidate in
                            AIMemoryLayerChip(layer: candidate, isSelected: layer == candidate) {
                                layer = candidate
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
        }
    }

    @ViewBuilder
    private var memoriesSection: some View {
        Section("记忆") {
            if let errorMessage {
                StatusBanner(text: errorMessage, kind: .error)
                    .listRowInsets(EdgeInsets())
            }
            if isLoading && snapshot.items.isEmpty {
                HStack { Spacer(); ProgressView("正在读取…"); Spacer() }
                    .padding(.vertical, 24)
            } else if snapshot.items.isEmpty {
                AIMemoryEmptyState(
                    hasFilter: primaryFilter == .daju || layer != nil || !searchText.isEmpty)
            } else {
                ForEach(snapshot.items) { item in
                    NavigationLink {
                        AIMemoryDetailView(item: item) {
                            Task { await load() }
                        }.appSubpageChrome()
                    } label: {
                        AIMemoryRow(item: item)
                    }
                }
                if snapshot.hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView() } else { Text("加载更多") }
                            Spacer()
                        }
                    }
                    .disabled(isLoading)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var refreshMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("整理共同聊天", systemImage: "person.2") {
                    Task { await refresh(.shared) }
                }
                Button("整理我的私聊", systemImage: "person") {
                    Task { await refresh(.privateMemory) }
                }
            } label: {
                if refreshingScope != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Label("整理记忆", systemImage: "sparkles")
                }
            }
            .disabled(refreshingScope != nil)
        }
    }

    private func load() async {
        guard let token = store.session?.token else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await store.memoryControl.fetch(
                scope: primaryFilter.scope,
                layer: primaryFilter == .daju ? nil : layer,
                query: searchText,
                perspective: primaryFilter.perspective,
                kind: primaryFilter == .daju ? dajuKind : .standard,
                token: token)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let token = store.session?.token,
              let cursor = snapshot.nextCursor,
              snapshot.hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await store.memoryControl.fetch(
                scope: primaryFilter.scope,
                layer: primaryFilter == .daju ? nil : layer,
                query: searchText,
                perspective: primaryFilter.perspective,
                kind: primaryFilter == .daju ? dajuKind : .standard,
                token: token,
                cursor: cursor)
            let known = Set(snapshot.items.map(\.id))
            snapshot = AIMemorySnapshot(
                items: snapshot.items + page.items.filter { !known.contains($0.id) },
                stats: page.stats,
                nextCursor: page.nextCursor,
                hasMore: page.hasMore)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh(_ target: AIMemoryScopeFilter) async {
        guard let token = store.session?.token else { return }
        refreshingScope = target
        defer { refreshingScope = nil }
        do {
            _ = try await store.memoryControl.refresh(target, token: token)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LoadKey: Hashable {
    let primaryFilter: AIMemoryPrimaryFilter
    let dajuKind: AIMemoryKind
    let layer: AIMemoryLayer?
    let query: String
}

private enum AIMemoryPrimaryFilter: String, CaseIterable, Identifiable {
    case all
    case shared
    case privateMemory
    case daju

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .shared: return "两人可见"
        case .privateMemory: return "仅自己"
        case .daju: return "大橘"
        }
    }

    var scope: AIMemoryScopeFilter {
        switch self {
        case .all, .daju: return .all
        case .shared: return .shared
        case .privateMemory: return .privateMemory
        }
    }

    var perspective: AIMemoryPerspective { self == .daju ? .daju : .people }
}
