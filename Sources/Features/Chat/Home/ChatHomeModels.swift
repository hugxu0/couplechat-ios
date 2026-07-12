import SwiftUI

// 聊天首页的纯数据与默认配置，不持有 Store。

struct ChatHomeStoredStatus: Codable, Identifiable, Equatable {
    let id: String
    var title: String
}

struct ChatHomeStatusOption: Identifiable, Equatable {
    let id: String
    let title: String
    let color: Color
}

struct ChatHomeQuickAction: Identifiable {
    let id: String
    let emoji: String
    let title: String
    let message: String
    let background: Color
    let kind: InteractionEffectKind
}

enum ChatHomeCatalog {
    static let defaultStatuses: [ChatHomeStoredStatus] = [
        .init(id: "miss", title: "在想你"),
        .init(id: "cling", title: "想贴贴"),
        .init(id: "busy", title: "忙完找你"),
        .init(id: "kiss", title: "要亲亲"),
    ]

    static let statusColors: [Color] = [
        Color(red: 0.78, green: 0.28, blue: 0.46),
        Color(red: 0.72, green: 0.30, blue: 0.48),
        Color(red: 0.38, green: 0.56, blue: 0.82),
        Color(red: 0.82, green: 0.54, blue: 0.26),
    ]

    static let actions: [ChatHomeQuickAction] = [
        .init(id: "miss", emoji: "💗", title: "想你了", message: "💗 想你了",
              background: Color(red: 1.00, green: 0.91, blue: 0.95), kind: .miss),
        .init(id: "pat", emoji: "🖐️", title: "拍一拍", message: "🖐️ 拍了拍你",
              background: Color(red: 1.00, green: 0.94, blue: 0.86), kind: .pat),
        .init(id: "flower", emoji: "🌸", title: "送花花", message: "🌸 送你一朵花花",
              background: Color(red: 1.00, green: 0.91, blue: 0.94), kind: .flower),
        .init(id: "poop", emoji: "💩", title: "扔粑粑", message: "💩 扔了个粑粑",
              background: Color(red: 0.96, green: 0.91, blue: 0.83), kind: .poop),
        .init(id: "note", emoji: "🪧", title: "贴条", message: "🪧 给你贴了一张小纸条",
              background: Color(red: 0.94, green: 0.95, blue: 0.97), kind: .note),
    ]

    static func statusOption(stored: ChatHomeStoredStatus, index: Int) -> ChatHomeStatusOption {
        ChatHomeStatusOption(
            id: stored.id,
            title: stored.title,
            color: statusColors[index % statusColors.count])
    }

    static func randomNoteText() -> String {
        [
            "先别划走，想你一下",
            "今天也要被我惦记",
            "看到这里就亲亲",
            "把坏心情撕掉",
            "给你贴一朵小开心",
        ].randomElement() ?? "想你一下"
    }
}
