import SwiftUI
import UIKit

// 存储空间 / 缓存管理页：查看本地占用、把云端聊天记录与图片全量同步到本地、清理缓存。
// 从「我的 → 存储空间」进入。参考 Telegram 的缓存管理：先看清占了多少，再决定同步/清理。

struct StorageView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var historySync: HistorySyncCoordinator
    @EnvironmentObject private var app: AppState

    @State private var breakdown: AppStorageBreakdown?
    @State private var showClearConfirm = false
    @State private var showClearMessagesConfirm = false

    private var operation: HistorySyncCoordinator.Operation { historySync.operation }
    private var remoteCounts: [String: Int] { historySync.remoteCounts }
    private var statusText: String? { historySync.outcome.text }
    private var statusIsError: Bool { historySync.outcome.isError }

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
            syncSection
            breakdownSection
            fileSection
            cleanupSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.pushSubpage(); refresh() }
        .onDisappear { app.popSubpage() }
        .onChange(of: historySync.operation) { refresh() }
        .confirmationDialog("清理图片缓存", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清理", role: .destructive) { clearCache() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清理已下载的图片，聊天记录不受影响。需要时会重新下载。")
        }
        .confirmationDialog("清除本地聊天记录？", isPresented: $showClearMessagesConfirm, titleVisibility: .visible) {
            Button("清除本地记录", role: .destructive) { clearLocalMessages() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除这台设备上的消息数据库，服务器上的聊天记录和上传文件不会删除；之后可以重新同步。")
        }
    }

    // MARK: - 总览

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sizeString(breakdown?.totalBytes ?? 0))
                            .font(DS.Typo.displayNumber)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text("当前设备上的聊天数据")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer()
                    connectionBadge
                }

                if !store.localCacheAvailable {
                    StatusBanner(
                        text: "本地缓存暂不可用，当前仍可使用云端聊天。",
                        kind: .warning)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.connected ? DS.Palette.green : DS.Palette.orange)
                .frame(width: 7, height: 7)
            Text(store.connected ? "云端已连接" : "等待连接")
                .font(DS.Typo.micro.weight(.semibold))
        }
        .foregroundStyle(store.connected ? DS.Palette.green : DS.Palette.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background((store.connected ? DS.Palette.green : DS.Palette.orange).opacity(0.10), in: Capsule())
    }

    // MARK: - 明细

    private var breakdownSection: some View {
        Section("占用明细") {
            breakdownRow(icon: "photo.stack", tint: DS.Palette.pink,
                         title: "聊天图片缓存",
                         detail: "\(breakdown?.cachedImageFiles ?? 0) 项 · \(sizeString(breakdown?.imageCacheBytes ?? 0))")
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
                .font(DS.Typo.button)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.85), in: RoundedRectangle(cornerRadius: DS.Radius.chip - 2, style: .continuous))
            Text(title)
                .font(DS.Typo.body)
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer()
            Text(detail)
                .font(DS.Typo.secondary)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 同步

    private var syncSection: some View {
        Section {
            syncProgressCard

            if operation.isRunning {
                Button(role: .cancel) { pauseOperation() } label: {
                    Label("暂停当前任务", systemImage: "pause.circle")
                }
            } else {
                Button { runFullSync() } label: {
                    Label("同步全部聊天记录", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!store.loggedIn)

                Button { runCacheImages() } label: {
                    Label("下载全部聊天图片", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!store.loggedIn)
            }
        } header: {
            Text("本地同步")
        } footer: {
            if let statusText {
                Text(statusText).foregroundStyle(statusIsError ? DS.Palette.orange : DS.Palette.green)
            } else if !store.connected {
                Text("需要先连接服务器才能同步聊天记录。")
            } else {
                Text("离开此页面会继续同步；App 被系统暂停后，下次会从已保存进度继续。图片单独下载，失败项会显示数量。")
            }
        }
    }

    @ViewBuilder
    private var syncProgressCard: some View {
        switch operation {
        case .idle:
            VStack(alignment: .leading, spacing: 9) {
                channelProgressRow("两人聊天", local: breakdown?.coupleMessages ?? 0, remote: remoteCounts[ChatChannel.couple.rawValue])
                channelProgressRow("大橘聊天", local: breakdown?.aiMessages ?? 0, remote: remoteCounts[ChatChannel.ai.rawValue])
            }
            .padding(.vertical, 3)
        case let .history(name, current, total):
            progressBlock(
                title: "正在同步\(name)",
                detail: total.map { "本地 \(current) / 云端 \($0) 条" } ?? "已保存 \(current) 条，正在读取云端总数",
                value: total.map { Double(min(current, $0)) }, total: total.map(Double.init))
        case let .images(done, total, failed):
            progressBlock(
                title: "正在下载聊天图片",
                detail: "已处理 \(done) / \(total) 项" + (failed > 0 ? " · \(failed) 项失败" : ""),
                value: Double(done), total: Double(max(total, 1)))
        }
    }

    private func channelProgressRow(_ title: String, local: Int, remote: Int?) -> some View {
        HStack {
            Text(title).font(DS.Typo.secondary.weight(.medium))
            Spacer()
            Text(remote.map { "\(local) / \($0) 条" } ?? "本地 \(local) 条")
                .font(DS.Typo.caption.monospacedDigit())
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func progressBlock(title: String, detail: String, value: Double?, total: Double?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ProgressView().controlSize(.small)
                Text(title).font(DS.Typo.button)
                Spacer()
            }
            if let value, let total {
                ProgressView(value: value, total: total).tint(DS.Palette.accent)
            } else {
                ProgressView().tint(DS.Palette.accent)
            }
            Text(detail)
                .font(DS.Typo.micro.monospacedDigit())
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.vertical, 3)
    }

    // MARK: - 清理

    private var fileSection: some View {
        Section {
            NavigationLink {
                AttachmentManagerView()
            } label: {
                Label("文件管理", systemImage: "folder")
                    .foregroundStyle(DS.Palette.textPrimary)
            }
        } header: {
            Text("媒体与文件")
        } footer: {
            Text("查看已同步到本地消息库里的图片、视频和文件记录。")
        }
    }

    // MARK: - 清理

    private var cleanupSection: some View {
        Section {
            DestructiveActionRow(title: "清理图片缓存", systemImage: "trash") {
                showClearConfirm = true
            }
            .disabled(operation.isRunning)

            DestructiveActionRow(
                title: "清除本地聊天记录",
                systemImage: "externaldrive.badge.minus"
            ) {
                showClearMessagesConfirm = true
            }
            .disabled(operation.isRunning)
        }
    }

    // MARK: - 动作

    private func refresh() {
        Task { breakdown = await store.localData.storageBreakdown() }
    }

    private func runFullSync() {
        historySync.startHistorySync()
    }

    private func runCacheImages() {
        historySync.startImageCaching()
    }

    private func pauseOperation() {
        historySync.pause()
    }

    private func clearCache() {
        store.localData.clearImageCache()
        refresh()
        historySync.showNotice("图片缓存已清理")
        Haptics.light()
    }

    private func clearLocalMessages() {
        Task {
            await store.clearLocalHistory()
            historySync.resetHistoryCounts()
            refresh()
            historySync.showNotice("本地聊天记录已清除，云端数据未受影响")
            Haptics.light()
        }
    }
}

private struct AttachmentManagerView: View {
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
