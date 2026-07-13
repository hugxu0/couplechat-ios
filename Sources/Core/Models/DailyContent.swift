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
    let diaries: [DiaryEntry]
    let recommend: Recommendation?

    private enum CodingKeys: String, CodingKey {
        case diary, diaries, recommend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diary = try container.decodeIfPresent(DiaryEntry.self, forKey: .diary)
        let decoded = try container.decodeIfPresent([DiaryEntry].self, forKey: .diaries) ?? []
        diaries = decoded.isEmpty ? diary.map { [$0] } ?? [] : decoded
        recommend = try container.decodeIfPresent(Recommendation.self, forKey: .recommend)
    }
}
