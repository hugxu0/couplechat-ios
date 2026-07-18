import Foundation

actor OutboxProcessor {
    private let persistence: any ChatPersistenceProtocol
    private var flushing = false
    private var flushRequested = false

    init(persistence: any ChatPersistenceProtocol = ChatPersistence.shared) {
        self.persistence = persistence
    }

    func replay(
        isConnected: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor (PendingOutboundMessage) async -> Bool
    ) async {
        guard !flushing else {
            flushRequested = true
            return
        }
        flushing = true

        repeat {
            flushRequested = false
            let pending = await persistence.loadPendingOutbounds()
            for item in pending where !item.requiresManualRetry {
                guard await isConnected() else { break }
                let sent = await send(item)
                if !sent {
                    let connected = await isConnected()
                    if !connected { break }
                }
            }
        } while flushRequested

        flushing = false
    }

    func allPending() async -> [PendingOutboundMessage] {
        await persistence.loadPendingOutbounds()
    }

    func pending(clientId: String) async -> PendingOutboundMessage? {
        await persistence.pendingOutbound(clientId: clientId)
    }

    func save(_ item: PendingOutboundMessage) async -> Bool {
        await persistence.upsertPendingOutbound(item)
    }

    func remove(clientId: String) async -> PendingOutboundMessage? {
        guard let item = await persistence.pendingOutbound(clientId: clientId) else { return nil }
        guard await persistence.deletePendingOutbound(clientId: clientId) else { return nil }
        return item
    }

    func complete(clientId: String) async {
        guard let item = await remove(clientId: clientId) else { return }
        removeLocalFiles(for: item)
    }

    func discard(clientId: String) async -> PendingOutboundMessage? {
        guard let item = await remove(clientId: clientId) else { return nil }
        removeLocalFiles(for: item)
        return item
    }

    func canRetry(_ item: PendingOutboundMessage) -> Bool {
        requiredLocalPaths(for: item).allSatisfy(FileManager.default.fileExists(atPath:))
    }

    private static let maxMediaBytes = 50 * 1024 * 1024

    nonisolated static func storageStats(username: String?) -> MediaCacheStats {
        guard let username else { return .empty }
        return MediaCacheStorage.stats(at: outboxDirectory(username: username))
    }

    func persistMedia(
        data: Data,
        mimeType: String,
        clientId: String,
        username: String
    ) -> URL? {
        guard data.count <= Self.maxMediaBytes else { return nil }
        return writeOutboxFile(clientId: clientId, username: username, mimeType: mimeType) { destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    /// 从已有文件复制到 outbox，避免视频/文件先整包读入内存再落盘。
    func persistMediaFile(
        source: URL,
        mimeType: String,
        clientId: String,
        username: String
    ) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 0,
              size <= Self.maxMediaBytes else { return nil }
        return writeOutboxFile(clientId: clientId, username: username, mimeType: mimeType) { destination in
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func writeOutboxFile(
        clientId: String,
        username: String,
        mimeType: String,
        write: (URL) throws -> Void
    ) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first else { return nil }
        let directory = Self.outboxDirectory(
            applicationSupport: applicationSupport,
            username: username)
        let ext = MediaUploadService.fileExtension(for: mimeType)
        let url = directory.appendingPathComponent(clientId).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            MediaCacheStorage.markDirectoryAsLocalCache(directory)
            try write(url)
            MediaCacheStorage.protect(url)
            return url
        } catch {
            return nil
        }
    }

    private func requiredLocalPaths(for item: PendingOutboundMessage) -> [String] {
        let attachments = item.attachments
            .filter { $0.uploadId == nil }
            .map(\.localFilePath)
        let media = item.isMedia && item.attachments.isEmpty && item.uploadId == nil
            ? item.localFilePath.map { [$0] } ?? []
            : []
        return attachments + media
    }

    private func removeLocalFiles(for item: PendingOutboundMessage) {
        let paths = (item.localFilePath.map { [$0] } ?? []) + item.attachments.map(\.localFilePath)
        for path in Set(paths) where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                print("[OutboxProcessor] Failed to remove file clientId=\(item.clientId)")
            }
        }
    }

    private nonisolated static func outboxDirectory(username: String) -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        return outboxDirectory(applicationSupport: applicationSupport, username: username)
    }

    private nonisolated static func outboxDirectory(
        applicationSupport: URL,
        username: String
    ) -> URL {
        let safeUsername = username
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return applicationSupport
            .appendingPathComponent("ChatOutboxMedia", isDirectory: true)
            .appendingPathComponent(safeUsername, isDirectory: true)
    }
}
