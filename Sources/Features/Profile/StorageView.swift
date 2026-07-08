import SwiftUI

// 存储空间 / 缓存管理页：查看本地占用、把云端聊天记录与图片全量同步到本地、清理缓存。
// 从「我的 → 存储空间」进入。参考 Telegram 的缓存管理：先看清占了多少，再决定同步/清理。

struct StorageView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var app: AppState

    @State private var breakdown: ChatStore.StorageBreakdown?
    @State private var syncing = false
    @State private var syncCount = 0
    @State private var caching = false
    @State private var cacheDone = 0
    @State private var cacheTotal = 0
    @State private var statusText: String?
    @State private var showClearConfirm = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private func sizeString(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    var body: some View {
        List {
            summarySection
            breakdownSection
            syncSection
            cleanupSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.pushSubpage(); refresh() }
        .onDisappear { app.popSubpage() }
        .confirmationDialog("清理图片缓存", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清理", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清理已下载的图片，聊天记录不受影响。需要时会重新下载。")
        }
    }

    // MARK: - 总览

    private var summarySection: some View {
        Section {
            VStack(spacing: 6) {
                Text(sizeString(breakdown?.totalBytes ?? 0))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("本地已用空间")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 明细

    private var breakdownSection: some View {
        Section("占用明细") {
            breakdownRow(icon: "photo.stack", tint: DS.Palette.pink,
                         title: "聊天图片缓存",
                         detail: sizeString(breakdown?.imageCacheBytes ?? 0))
            breakdownRow(icon: "externaldrive", tint: DS.Palette.blue,
                         title: "消息数据库",
                         detail: sizeString(breakdown?.databaseBytes ?? 0))
            breakdownRow(icon: "message", tint: DS.Palette.purple,
                         title: "已缓存消息",
                         detail: "两人 \(breakdown?.coupleMessages ?? 0) · 大橘 \(breakdown?.aiMessages ?? 0)")
        }
    }

    private func breakdownRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 同步

    private var syncSection: some View {
        Section {
            // 全量同步聊天记录
            Button {
                runFullSync()
            } label: {
                HStack {
                    Label("同步全部聊天记录", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(store.connected ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                    Spacer()
                    if syncing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("\(syncCount)").font(.system(size: 13, design: .rounded).monospacedDigit())
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                }
            }
            .disabled(syncing || caching || !store.connected)

            // 缓存全部图片
            Button {
                runCacheImages()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("缓存全部图片到本地", systemImage: "square.and.arrow.down.on.square")
                            .foregroundStyle(caching ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                        Spacer()
                        if caching {
                            Text("\(cacheDone)/\(cacheTotal)")
                                .font(.system(size: 13, design: .rounded).monospacedDigit())
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    if caching && cacheTotal > 0 {
                        ProgressView(value: Double(cacheDone), total: Double(cacheTotal))
                            .tint(DS.Palette.accent)
                    }
                }
            }
            .disabled(syncing || caching)
        } header: {
            Text("同步与缓存")
        } footer: {
            if let statusText {
                Text(statusText).foregroundStyle(DS.Palette.green)
            } else if !store.connected {
                Text("需要先连接服务器才能同步聊天记录。")
            } else {
                Text("同步会把云端全部聊天记录拉到本地，缓存图片后离线也能看。数据较多时可能需要一点时间。")
            }
        }
    }

    // MARK: - 清理

    private var cleanupSection: some View {
        Section {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清理图片缓存", systemImage: "trash")
            }
            .disabled(syncing || caching)
        }
    }

    // MARK: - 动作

    private func refresh() {
        breakdown = store.storageBreakdown()
    }

    private func runFullSync() {
        guard !syncing else { return }
        syncing = true
        syncCount = 0
        statusText = nil
        Task {
            let coupleTotal = await store.syncAllHistory(.couple) { count in
                Task { @MainActor in syncCount = count }
            }
            let aiTotal = await store.syncAllHistory(.ai) { count in
                Task { @MainActor in syncCount = coupleTotal + count }
            }
            await MainActor.run {
                syncing = false
                refresh()
                statusText = "已同步 \(coupleTotal + aiTotal) 条消息"
                Haptics.medium()
            }
        }
    }

    private func runCacheImages() {
        guard !caching else { return }
        caching = true
        cacheDone = 0
        cacheTotal = 0
        statusText = nil
        Task {
            await store.cacheAllImages(.couple) { done, total in
                Task { @MainActor in cacheDone = done; cacheTotal = total }
            }
            await store.cacheAllImages(.ai) { done, total in
                Task { @MainActor in cacheDone = done; cacheTotal = total }
            }
            await MainActor.run {
                caching = false
                refresh()
                statusText = "图片已全部缓存到本地"
                Haptics.medium()
            }
        }
    }

    private func clearCache() {
        store.clearImageCache()
        refresh()
        statusText = "图片缓存已清理"
        Haptics.light()
    }
}
