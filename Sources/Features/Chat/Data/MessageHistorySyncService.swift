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
        scope: ChatPersistenceScope,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> MessageHistorySyncResult {
        guard var localCount = await persistence.messageCount(
            channel: channel.rawValue,
            scope: scope
        ) else {
            return MessageHistorySyncResult(
                localCount: 0,
                remoteTotal: nil,
                downloaded: 0,
                completed: false,
                error: "登录会话已切换")
        }
        let defaults = UserDefaults.standard
        let keys = Self.checkpointKeys(username: session.username, channel: channel)
        var cursorTimestamp = defaults.object(forKey: keys.cursorTimestamp) as? Double
        var cursorID = defaults.string(forKey: keys.cursorID)
        let checkpointLocalCount = defaults.object(forKey: keys.localCount) as? Int
        if cursorTimestamp != nil,
           (cursorID?.isEmpty != false ||
               checkpointLocalCount.map({ localCount < $0 }) ?? true) {
            Self.clearCheckpoint(keys, defaults: defaults)
            cursorTimestamp = nil
            cursorID = nil
        }
        // 从断点继续的任务如果最终仍对不上总数，会自动再做一次从最新页开始的
        // 修复扫描；从最新页开始的任务则不会无休止重复。
        var passStartedFromLatest = cursorTimestamp == nil
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
                before: cursorTimestamp,
                beforeId: cursorID,
                limit: pageLimit,
                session: session)
            guard await persistence.isActive(scope: scope) else {
                lastError = "登录会话已切换"
                break
            }
            if let total = page.total { remoteTotal = total }
            onProgress(localCount, remoteTotal)
            if let error = page.error {
                lastError = error
                break
            }
            guard !page.messages.isEmpty else {
                completed = remoteTotal.map { localCount >= $0 } ?? true
                if !completed, cursorTimestamp != nil, !passStartedFromLatest {
                    Self.clearCheckpoint(keys, defaults: defaults)
                    cursorTimestamp = nil
                    cursorID = nil
                    passStartedFromLatest = true
                    continue
                }
                if !completed, let remoteTotal {
                    lastError = "云端仍有 \(max(0, remoteTotal - localCount)) 条消息未同步，请重试"
                }
                break
            }
            guard let persisted = await persistence.insertMessages(
                page.messages,
                scope: scope
            ) else {
                lastError = "登录会话已切换"
                break
            }
            guard persisted == page.messages.count else {
                lastError = "写入本地数据库失败"
                break
            }
            guard let refreshedCount = await persistence.messageCount(
                channel: channel.rawValue,
                scope: scope
            ) else {
                lastError = "登录会话已切换"
                break
            }
            localCount = refreshedCount
            downloaded = max(0, localCount - initialLocalCount)
            onProgress(localCount, remoteTotal)

            let batchOldest = page.messages.min {
                ChatMessageCollection.isOrderedBefore($0, $1)
            }
            if page.messages.count < pageLimit {
                completed = remoteTotal.map { localCount >= $0 } ?? true
                if !completed, cursorTimestamp != nil, !passStartedFromLatest {
                    Self.clearCheckpoint(keys, defaults: defaults)
                    cursorTimestamp = nil
                    cursorID = nil
                    passStartedFromLatest = true
                    continue
                }
                if !completed, let remoteTotal {
                    lastError = "本地 \(localCount) 条，云端 \(remoteTotal) 条，记录仍未补齐"
                }
                break
            }
            if let batchOldest,
               let previousTimestamp = cursorTimestamp,
               let previousID = cursorID,
               batchOldest.ts > previousTimestamp ||
                   (batchOldest.ts == previousTimestamp && batchOldest.id >= previousID) {
                lastError = "同步游标未继续前进"
                break
            }
            if let batchOldest {
                cursorTimestamp = batchOldest.ts
                cursorID = batchOldest.id
                defaults.set(batchOldest.ts, forKey: keys.cursorTimestamp)
                defaults.set(batchOldest.id, forKey: keys.cursorID)
                defaults.set(localCount, forKey: keys.localCount)
            }
        }

        if Task.isCancelled { lastError = "同步已暂停" }
        if completed && lastError == nil {
            Self.clearCheckpoint(keys, defaults: defaults)
        }
        if let refreshedCount = await persistence.messageCount(
            channel: channel.rawValue,
            scope: scope
        ) {
            localCount = refreshedCount
        } else if lastError == nil {
            lastError = "登录会话已切换"
        }
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
    ) -> (cursorTimestamp: String, cursorID: String, localCount: String) {
        let suffix = "\(username).\(channel.rawValue)"
        return (
            cursorTimestamp: "history.sync.v3.cursor-ts.\(suffix)",
            cursorID: "history.sync.v3.cursor-id.\(suffix)",
            localCount: "history.sync.v3.local-count.\(suffix)")
    }

    private static func clearCheckpoint(
        _ keys: (cursorTimestamp: String, cursorID: String, localCount: String),
        defaults: UserDefaults
    ) {
        defaults.removeObject(forKey: keys.cursorTimestamp)
        defaults.removeObject(forKey: keys.cursorID)
        defaults.removeObject(forKey: keys.localCount)
    }
}
