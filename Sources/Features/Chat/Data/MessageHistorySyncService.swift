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
        var oldest = await persistence.oldestMessageTimestamp(channel: channel.rawValue)
        var localCount = await persistence.messageCount(channel: channel.rawValue)
        var remoteTotal: Int?
        var downloaded = 0
        var completed = false
        var lastError: String?
        let pageLimit = 300
        onProgress(localCount, nil)

        while !Task.isCancelled {
            let page = await remoteDataSource.fetchHistoryPage(
                channel: channel,
                before: oldest,
                limit: pageLimit,
                session: session)
            if let total = page.total { remoteTotal = total }
            onProgress(localCount, remoteTotal)
            if let error = page.error {
                lastError = error
                break
            }
            guard !page.messages.isEmpty else {
                completed = true
                break
            }
            let persisted = await persistence.insertMessages(page.messages)
            guard persisted == page.messages.count else {
                lastError = "写入本地数据库失败"
                break
            }
            downloaded += page.messages.count
            localCount = await persistence.messageCount(channel: channel.rawValue)
            onProgress(localCount, remoteTotal)

            let batchOldest = page.messages.map(\.ts).min()
            if page.messages.count < pageLimit {
                completed = true
                break
            }
            if let batchOldest, let previous = oldest, batchOldest >= previous {
                lastError = "同步游标未继续前进"
                break
            }
            oldest = batchOldest
        }

        if Task.isCancelled { lastError = "同步已暂停" }
        localCount = await persistence.messageCount(channel: channel.rawValue)
        if let remoteTotal, localCount >= remoteTotal { completed = true }
        return MessageHistorySyncResult(
            localCount: localCount,
            remoteTotal: remoteTotal,
            downloaded: downloaded,
            completed: completed && lastError == nil,
            error: lastError)
    }
}
