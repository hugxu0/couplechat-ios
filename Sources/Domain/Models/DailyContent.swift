import Foundation

struct DayStat: Decodable, Equatable {
    let date: String
    let weekday: String
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }
}

struct MonthStat: Decodable, Equatable {
    let month: String
    let counts: [String: Int]

    var total: Int { counts.values.reduce(0, +) }
}

struct DiaryEntry: Decodable, Equatable {
    let date: String
    let text: String
}

struct DailyContent: Decodable, Equatable {
    let diaries: [DiaryEntry]
    let backfilling: Bool
    let requestedDays: Int

    private enum CodingKeys: String, CodingKey {
        case diaries, backfilling, requestedDays
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        diaries = try values.decodeIfPresent([DiaryEntry].self, forKey: .diaries) ?? []
        backfilling = try values.decodeIfPresent(Bool.self, forKey: .backfilling) ?? false
        requestedDays = try values.decodeIfPresent(Int.self, forKey: .requestedDays) ?? 30
    }
}
