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
            for item in pending {
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

    func persistMedia(
        data: Data,
        mimeType: String,
        clientId: String,
        username: String
    ) -> URL? {
        guard data.count <= 50 * 1024 * 1024,
              let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask).first else { return nil }
        let safeUsername = username
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = applicationSupport
            .appendingPathComponent("ChatOutboxMedia", isDirectory: true)
            .appendingPathComponent(safeUsername, isDirectory: true)
        let ext = MediaUploadService.fileExtension(for: mimeType)
        let url = directory.appendingPathComponent(clientId).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
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
}
