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
}
