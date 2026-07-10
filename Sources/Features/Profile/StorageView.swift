import SwiftUI
import UIKit

// 存储空间 / 缓存管理页：查看本地占用、把云端聊天记录与图片全量同步到本地、清理缓存。
// 从「我的 → 存储空间」进入。参考 Telegram 的缓存管理：先看清占了多少，再决定同步/清理。

struct StorageView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var app: AppState

    @State private var breakdown: ChatStore.StorageBreakdown?
    @State private var operation: SyncOperation = .idle
    @State private var operationTask: Task<Void, Never>?
    @State private var remoteCounts: [String: Int] = [:]
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var showClearConfirm = false
    @State private var showClearMessagesConfirm = false

    private enum SyncOperation: Equatable {
        case idle
        case history(name: String, current: Int, total: Int?)
        case images(done: Int, total: Int, failed: Int)

        var isRunning: Bool { self != .idle }
    }

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
        .onDisappear { operationTask?.cancel() }
    }

    // MARK: - 总览

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sizeString(breakdown?.totalBytes ?? 0))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text("当前设备上的聊天数据")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer()
                    connectionBadge
                }

                if store.auth.recoveredLocalCache {
                    Label("检测到旧缓存异常，已安全隔离并新建本地数据库。云端记录可重新同步。", systemImage: "wrench.and.screwdriver.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.connected ? DS.Palette.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(store.connected ? "云端已连接" : "等待连接")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(store.connected ? DS.Palette.green : Color.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background((store.connected ? DS.Palette.green : Color.orange).opacity(0.10), in: Capsule())
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
            syncProgressCard

            if operation.isRunning {
                Button(role: .cancel) { pauseOperation() } label: {
                    Label("暂停当前任务", systemImage: "pause.circle")
                }
            } else {
                Button { runFullSync() } label: {
                    Label("同步全部聊天记录", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!store.connected)

                Button { runCacheImages() } label: {
                    Label("下载全部聊天图片", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!store.connected)
            }
        } header: {
            Text("本地同步")
        } footer: {
            if let statusText {
                Text(statusText).foregroundStyle(statusIsError ? Color.orange : DS.Palette.green)
            } else if !store.connected {
                Text("需要先连接服务器才能同步聊天记录。")
            } else {
                Text("聊天记录支持断点续传；退出后再次同步会从上次位置继续。图片单独下载，失败项会显示数量。")
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
            Text(title).font(.system(size: 14, weight: .medium))
            Spacer()
            Text(remote.map { "\(local) / \($0) 条" } ?? "本地 \(local) 条")
                .font(.system(size: 13, design: .rounded).monospacedDigit())
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func progressBlock(title: String, detail: String, value: Double?, total: Double?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ProgressView().controlSize(.small)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            if let value, let total {
                ProgressView(value: value, total: total).tint(DS.Palette.accent)
            } else {
                ProgressView().tint(DS.Palette.accent)
            }
            Text(detail)
                .font(.system(size: 12, design: .rounded).monospacedDigit())
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
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("清理图片缓存", systemImage: "trash")
            }
            .disabled(operation.isRunning)

            Button(role: .destructive) {
                showClearMessagesConfirm = true
            } label: {
                Label("清除本地聊天记录", systemImage: "externaldrive.badge.minus")
            }
            .disabled(operation.isRunning)
        }
    }

    // MARK: - 动作

    private func refresh() {
        breakdown = store.storageBreakdown()
    }

    private func runFullSync() {
        guard !operation.isRunning, store.connected else { return }
        statusText = nil
        statusIsError = false
        operationTask = Task {
            var downloaded = 0
            var errors: [String] = []
            for (channel, name) in [(ChatChannel.couple, "两人聊天"), (.ai, "大橘聊天")] {
                if Task.isCancelled { break }
                let result = await store.syncAllHistory(channel) { current, total in
                    operation = .history(name: name, current: current, total: total)
                    if let total { remoteCounts[channel.rawValue] = total }
                    refresh()
                }
                downloaded += result.downloaded
                if let total = result.remoteTotal { remoteCounts[channel.rawValue] = total }
                if let error = result.error, error != "同步已暂停" { errors.append("\(name)：\(error)") }
            }
            operation = .idle
            refresh()
            if Task.isCancelled {
                statusText = "同步已暂停，下次会从当前位置继续"
            } else if errors.isEmpty {
                statusText = downloaded > 0 ? "同步完成，本次新增 \(downloaded) 条消息" : "本地聊天记录已是最新"
                Haptics.medium()
            } else {
                statusIsError = true
                statusText = errors.joined(separator: "；")
            }
        }
    }

    private func runCacheImages() {
        guard !operation.isRunning, store.connected else { return }
        statusText = nil
        statusIsError = false
        operationTask = Task {
            let result = await store.cacheAllImages { done, total, failed in
                operation = .images(done: done, total: total, failed: failed)
            }
            operation = .idle
            refresh()
            if Task.isCancelled {
                statusText = "图片下载已暂停"
            } else if result.failed == 0 {
                statusText = result.total == 0 ? "当前没有需要下载的聊天图片" : "\(result.succeeded) 张图片已保存在本地"
                Haptics.medium()
            } else {
                statusIsError = true
                statusText = "已保存 \(result.succeeded) 张，\(result.failed) 张下载失败，可稍后重试"
            }
        }
    }

    private func pauseOperation() {
        operationTask?.cancel()
        operationTask = nil
    }

    private func clearCache() {
        store.clearImageCache()
        refresh()
        statusText = "图片缓存已清理"
        statusIsError = false
        Haptics.light()
    }

    private func clearLocalMessages() {
        store.clearLocalHistory()
        remoteCounts = [:]
        refresh()
        statusText = "本地聊天记录已清除，云端数据未受影响"
        statusIsError = false
        Haptics.light()
    }
}

private struct AttachmentManagerView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var app: AppState
    @State private var channel: ChatChannel = .couple

    private var items: [ChatMessage] {
        store.mediaMessages(for: channel, includeFiles: true, limit: 300)
    }

    var body: some View {
        List {
            Picker("频道", selection: $channel) {
                Text("两人").tag(ChatChannel.couple)
                Text("大橘").tag(ChatChannel.ai)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if items.isEmpty {
                ContentUnavailableView("暂无媒体或文件", systemImage: "folder")
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
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(tint(for: item.type), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(for: item))
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(DS.Palette.textPrimary)
                                        .lineLimit(1)
                                    Text(dateTime(item.ts))
                                        .font(.system(size: 12))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
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
