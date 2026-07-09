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

struct Recommendation: Decodable, Equatable {
    let category: String
    let title: String
    let reason: String
}

struct DailyContent: Decodable, Equatable {
    let diary: DiaryEntry?
    let recommend: Recommendation?
}
