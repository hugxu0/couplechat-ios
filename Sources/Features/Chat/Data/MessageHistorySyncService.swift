import Foundation

struct MessageHistorySyncResult: Equatable {
    let localCount: Int
    let remoteTotal: Int?
    let downloaded: Int
    let completed: Bool
    let error: String?
}

/// 负责完整历史分页与落库，页面 Store 只接收最终结果并刷新最近窗口。
@MainActor
struct MessageHistorySyncService {
    private let persistence: any ChatPersistenceProtocol
    private let remoteDataSource: ChatRemoteDataSource

    init(
        persistence: any ChatPersistenceProtocol,
        remoteDataSource: ChatRemoteDataSource
    ) {
        self.persistence = persistence
        self.remoteDataSource = remoteDataSource
    }

    func sync(
        channel: ChatChannel,
        session: Session,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> MessageHistorySyncResult {
        var localCount = await persistence.messageCount(channel: channel.rawValue)
        let defaults = UserDefaults.standard
        let keys = Self.checkpointKeys(username: session.username, channel: channel)
        // v1 断点只保存时间，不知道它对应的是不是当前 SQLite 文件。一旦本地库被
        // 清理、恢复或出现中间缺口，继续使用它就会永远绕过缺失区间。
        defaults.removeObject(forKey: keys.legacyCursor)
        var cursor = defaults.object(forKey: keys.cursor) as? Double
        let checkpointLocalCount = defaults.object(forKey: keys.localCount) as? Int
        if cursor != nil,
           checkpointLocalCount.map({ localCount < $0 }) ?? true {
            Self.clearCheckpoint(keys, defaults: defaults)
            cursor = nil
        }
        // 从断点继续的任务如果最终仍对不上总数，会自动再做一次从最新页开始的
        // 修复扫描；从最新页开始的任务则不会无休止重复。
        var passStartedFromLatest = cursor == nil
        let initialLocalCount = localCount
        var remoteTotal: Int?
        var downloaded = 0
        var completed = false
        var lastError: String?
        let pageLimit = 300
        onProgress(localCount, nil)

        while !Task.isCancelled {
            let page = await remoteDataSource.fetchHistoryPage(
                channel: channel,
                before: cursor,
                limit: pageLimit,
                session: session)
            if let total = page.total { remoteTotal = total }
            onProgress(localCount, remoteTotal)
            if let error = page.error {
                lastError = error
                break
            }
            if let remoteTotal, localCount >= remoteTotal {
                completed = true
                break
            }
            guard !page.messages.isEmpty else {
                completed = remoteTotal.map { localCount >= $0 } ?? true
                if !completed, cursor != nil, !passStartedFromLatest {
                    Self.clearCheckpoint(keys, defaults: defaults)
                    cursor = nil
                    passStartedFromLatest = true
                    continue
                }
                if !completed, let remoteTotal {
                    lastError = "云端仍有 \(max(0, remoteTotal - localCount)) 条消息未同步，请重试"
                }
                break
            }
            let persisted = await persistence.insertMessages(page.messages)
            guard persisted == page.messages.count else {
                lastError = "写入本地数据库失败"
                break
            }
            localCount = await persistence.messageCount(channel: channel.rawValue)
            downloaded = max(0, localCount - initialLocalCount)
            onProgress(localCount, remoteTotal)
            if let remoteTotal, localCount >= remoteTotal {
                completed = true
                break
            }

            let batchOldest = page.messages.map(\.ts).min()
            if page.messages.count < pageLimit {
                completed = remoteTotal.map { localCount >= $0 } ?? true
                if !completed, cursor != nil, !passStartedFromLatest {
                    Self.clearCheckpoint(keys, defaults: defaults)
                    cursor = nil
                    passStartedFromLatest = true
                    continue
                }
                if !completed, let remoteTotal {
                    lastError = "本地 \(localCount) 条，云端 \(remoteTotal) 条，记录仍未补齐"
                }
                break
            }
            if let batchOldest, let previous = cursor, batchOldest >= previous {
                lastError = "同步游标未继续前进"
                break
            }
            cursor = batchOldest
            if let cursor {
                defaults.set(cursor, forKey: keys.cursor)
                defaults.set(localCount, forKey: keys.localCount)
            }
        }

        if Task.isCancelled { lastError = "同步已暂停" }
        if completed && lastError == nil {
            Self.clearCheckpoint(keys, defaults: defaults)
        }
        localCount = await persistence.messageCount(channel: channel.rawValue)
        return MessageHistorySyncResult(
            localCount: localCount,
            remoteTotal: remoteTotal,
            downloaded: downloaded,
            completed: completed && lastError == nil,
            error: lastError)
    }

    static func resetCheckpoint(username: String, channel: ChatChannel) {
        clearCheckpoint(
            checkpointKeys(username: username, channel: channel),
            defaults: .standard)
    }

    private static func checkpointKeys(
        username: String,
        channel: ChatChannel
    ) -> (cursor: String, localCount: String, legacyCursor: String) {
        let suffix = "\(username).\(channel.rawValue)"
        return (
            cursor: "history.sync.v2.cursor.\(suffix)",
            localCount: "history.sync.v2.local-count.\(suffix)",
            legacyCursor: "history.sync.cursor.\(suffix)")
    }

    private static func clearCheckpoint(
        _ keys: (cursor: String, localCount: String, legacyCursor: String),
        defaults: UserDefaults
    ) {
        defaults.removeObject(forKey: keys.cursor)
        defaults.removeObject(forKey: keys.localCount)
        defaults.removeObject(forKey: keys.legacyCursor)
    }
}
