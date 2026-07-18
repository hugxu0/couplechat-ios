import Foundation

struct AppLocalStatsBuckets {
    let days: [DayStat]
    let months: [MonthStat]
}

struct AppStorageBreakdown {
    var imageCacheBytes: Int64
    var voiceCacheBytes: Int64
    var fileCacheBytes: Int64
    var outboxBytes: Int64
    var databaseBytes: Int64
    var cachedImageFiles: Int
    var cachedVoiceFiles: Int
    var cachedPreviewFiles: Int
    var outboxFiles: Int
    var coupleMessages: Int
    var aiMessages: Int
    var totalBytes: Int64 {
        imageCacheBytes + voiceCacheBytes + fileCacheBytes + outboxBytes + databaseBytes
    }
}

struct AppMediaCacheResult: Equatable {
    let total: Int
    let completed: Int
    let failed: Int
    var succeeded: Int { completed - failed }
}

actor LocalDataRepository {
    private let persistence: any ChatPersistenceProtocol

    init(persistence: any ChatPersistenceProtocol = ChatPersistence.shared) {
        self.persistence = persistence
    }

    func stats(for channel: ChatChannel = .couple) async -> AppLocalStatsBuckets {
        let calendar = Self.shanghaiCalendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let earliestDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var dayCounts: [String: [String: Int]] = [:]
        var monthCounts: [String: [String: Int]] = [:]

        for row in await persistence.dayCounts(channel: channel.rawValue) {
            guard let date = Self.dayFormatter.date(from: row.date),
                  calendar.startOfDay(for: date) >= earliestDay else { continue }
            dayCounts[row.date, default: [:]][row.sender] = row.count
        }
        for row in await persistence.monthCounts(channel: channel.rawValue) {
            monthCounts[row.date, default: [:]][row.sender] = row.count
        }

        var days: [DayStat] = []
        var cursor = earliestDay
        while cursor <= today {
            let key = Self.dayFormatter.string(from: cursor)
            let index = calendar.component(.weekday, from: cursor) - 1
            let weekday = calendar.isDate(cursor, inSameDayAs: today) ? "今" : Self.weekdayLabels[index]
            days.append(DayStat(date: key, weekday: weekday, counts: dayCounts[key] ?? [:]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let thisMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let parsedMonths = monthCounts.keys.compactMap(Self.monthFormatter.date(from:))
        var monthCursor = parsedMonths.min() ?? thisMonth
        var months: [MonthStat] = []
        while monthCursor <= thisMonth {
            let key = Self.monthFormatter.string(from: monthCursor)
            months.append(MonthStat(month: key, counts: monthCounts[key] ?? [:]))
            guard let next = calendar.date(byAdding: .month, value: 1, to: monthCursor) else { break }
            monthCursor = next
        }
        return AppLocalStatsBuckets(days: days, months: months)
    }

    func storageBreakdown(username: String? = nil) async -> AppStorageBreakdown {
        let downloaded = await MediaFileCache.shared.stats()
        let outbox = OutboxProcessor.storageStats(username: username)
        return await AppStorageBreakdown(
            imageCacheBytes: ImageCache.shared.diskUsageBytes(),
            voiceCacheBytes: downloaded.voice.bytes,
            fileCacheBytes: downloaded.files.bytes,
            outboxBytes: outbox.bytes,
            databaseBytes: persistence.databaseSizeBytes(),
            cachedImageFiles: ImageCache.shared.cachedFileCount(),
            cachedVoiceFiles: downloaded.voice.fileCount,
            cachedPreviewFiles: downloaded.files.fileCount,
            outboxFiles: outbox.fileCount,
            coupleMessages: persistence.messageCount(channel: ChatChannel.couple.rawValue),
            aiMessages: persistence.messageCount(channel: ChatChannel.ai.rawValue))
    }

    func cacheAllImages(
        channels: [ChatChannel] = ChatChannel.allCases,
        onProgress: @escaping (_ completed: Int, _ total: Int, _ failed: Int) -> Void
    ) async -> AppMediaCacheResult {
        var rawURLs: [String] = []
        for channel in channels {
            rawURLs += await persistence.mediaURLs(
                channel: channel.rawValue, types: ["image", "sticker"])
        }
        var seen: Set<String> = []
        let urls = rawURLs.compactMap(ServerConfig.resolveMediaURL).filter {
            seen.insert(MediaCacheIdentity.value(for: $0)).inserted
        }
        onProgress(0, urls.count, 0)
        var completed = 0
        var failed = 0
        for url in urls {
            if Task.isCancelled { break }
            if !ImageCache.shared.isCached(url), await ImageCache.shared.image(for: url) == nil {
                failed += 1
            }
            completed += 1
            onProgress(completed, urls.count, failed)
        }
        return AppMediaCacheResult(total: urls.count, completed: completed, failed: failed)
    }

    func clearDownloadedMedia() async {
        await ImageCache.shared.clearAllAsync()
        await MediaFileCache.shared.clearAll()
    }

    private static let weekdayLabels = ["日", "一", "二", "三", "四", "五", "六"]
    private static var shanghaiCalendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }()
    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM-dd"
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return value
    }()
    private static let monthFormatter: DateFormatter = {
        let value = DateFormatter()
        value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.dateFormat = "yyyy-MM"
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return value
    }()
}
