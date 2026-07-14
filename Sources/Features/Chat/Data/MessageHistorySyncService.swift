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
        // 每次都从云端最新一页向前核对。旧实现从“本地最早消息”继续向前，
        // 只能补更老的记录，最近缺失或中间断层永远不会被补齐。
        var cursor: Double?
        var localCount = await persistence.messageCount(channel: channel.rawValue)
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
            guard !page.messages.isEmpty else {
                completed = remoteTotal.map { localCount >= $0 } ?? true
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

            let batchOldest = page.messages.map(\.ts).min()
            if page.messages.count < pageLimit {
                completed = remoteTotal.map { localCount >= $0 } ?? true
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
        }

        if Task.isCancelled { lastError = "同步已暂停" }
        localCount = await persistence.messageCount(channel: channel.rawValue)
        return MessageHistorySyncResult(
            localCount: localCount,
            remoteTotal: remoteTotal,
            downloaded: downloaded,
            completed: completed && lastError == nil,
            error: lastError)
    }
}
