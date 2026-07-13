import Foundation

// MARK: - 对方推荐的数据模型（存在 shared["partner_recommend"]）

struct PartnerRecommend: Equatable {
    let id: String
    let from: String
    let fromName: String
    let text: String
    let ts: Double

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let from = dict["from"] as? String,
              let text = dict["text"] as? String, !text.isEmpty else { return nil }
        self.id = id
        self.from = from
        self.fromName = dict["fromName"] as? String ?? "TA"
        self.text = text
        self.ts = (dict["ts"] as? NSNumber)?.doubleValue ?? 0
    }
}
