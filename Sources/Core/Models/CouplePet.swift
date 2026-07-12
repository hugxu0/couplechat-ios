import Foundation

struct CouplePetSnapshot: Codable, Equatable {
    let pet: CouplePetState
}

struct CouplePetState: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let version: Int
    let scene: PetSceneState
    let today: PetDailyPrompt?
    let inventory: [PetCollectible]
    let moments: [PetMoment]
    let latestInteraction: PetInteractionRecord?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "大橘"
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        scene = try values.decodeIfPresent(PetSceneState.self, forKey: .scene) ?? .fallback
        today = try values.decodeIfPresent(PetDailyPrompt.self, forKey: .today)
        inventory = try values.decodeIfPresent([PetCollectible].self, forKey: .inventory) ?? []
        moments = try values.decodeIfPresent([PetMoment].self, forKey: .moments) ?? []
        latestInteraction = try values.decodeIfPresent(
            PetInteractionRecord.self, forKey: .latestInteraction)
    }
}

struct PetSceneState: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let artworkURL: String?
    let placedItemIds: [String]

    static let fallback = PetSceneState(
        id: "window_nook",
        title: "窗边小窝",
        artworkURL: nil,
        placedItemIds: [])

    init(id: String, title: String, artworkURL: String?, placedItemIds: [String]) {
        self.id = id
        self.title = title
        self.artworkURL = artworkURL
        self.placedItemIds = placedItemIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? "window_nook"
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "窗边小窝"
        artworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL)
        placedItemIds = try values.decodeIfPresent([String].self, forKey: .placedItemIds) ?? []
    }
}

struct PetDailyPrompt: Codable, Equatable, Identifiable {
    let id: String
    let prompt: String
    let responseType: String
    let status: String
    let responses: [PetPromptResponse]
    let reward: PetReward?

    var isCompleted: Bool {
        status == "completed" || status == "settled" || responses.count >= 2
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt) ?? "今天想一起留下什么？"
        responseType = try values.decodeIfPresent(String.self, forKey: .responseType) ?? "text"
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "open"
        responses = try values.decodeIfPresent([PetPromptResponse].self, forKey: .responses) ?? []
        reward = try values.decodeIfPresent(PetReward.self, forKey: .reward)
    }
}

/// 兼容候选协议中的经验/金币字段；当前玩法不结算通用金币，客户端只呈现共同内容藏品。
struct PetReward: Codable, Equatable {
    let experience: Int
    let coins: Int
    let item: PetCollectible?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        experience = try values.decodeIfPresent(Int.self, forKey: .experience) ?? 0
        coins = try values.decodeIfPresent(Int.self, forKey: .coins) ?? 0
        item = try values.decodeIfPresent(PetCollectible.self, forKey: .item)
    }
}

struct PetPromptResponse: Codable, Equatable, Identifiable {
    let username: String
    let displayName: String
    let text: String
    let respondedAt: Int64

    var id: String { username }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        username = try values.decode(String.self, forKey: .username)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName) ?? username
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        respondedAt = try values.decodeIfPresent(Int64.self, forKey: .respondedAt) ?? 0
    }
}

struct PetCollectible: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let symbolName: String?
    let unlockedAt: Int64
    let isPlaced: Bool
    let quantity: Int

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "共同藏品"
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "memory"
        symbolName = try values.decodeIfPresent(String.self, forKey: .symbolName)
        unlockedAt = try values.decodeIfPresent(Int64.self, forKey: .unlockedAt) ?? 0
        isPlaced = try values.decodeIfPresent(Bool.self, forKey: .isPlaced) ?? false
        quantity = try values.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
    }
}

struct PetMoment: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let createdAt: Int64

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "共同足迹"
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        createdAt = try values.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }
}

struct PetInteractionRecord: Codable, Equatable, Identifiable {
    let id: String
    let kind: PetInteractionKind
    let actorName: String
    let createdAt: Int64

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let rawKind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "stroke"
        kind = PetInteractionKind(rawValue: rawKind) ?? .stroke
        actorName = try values.decodeIfPresent(String.self, forKey: .actorName) ?? "对方"
        createdAt = try values.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }
}

enum PetInteractionKind: String, Codable, CaseIterable, Identifiable {
    case stroke
    case highFive = "high_five"
    case teaser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stroke: return "摸摸"
        case .highFive: return "碰爪"
        case .teaser: return "逗猫棒"
        }
    }

    var systemImage: String {
        switch self {
        case .stroke: return "hand.raised.fingers.spread"
        case .highFive: return "pawprint.fill"
        case .teaser: return "wand.and.sparkles"
        }
    }

    var confirmation: String {
        switch self {
        case .stroke: return "舒服得眯起眼睛了"
        case .highFive: return "大橘认真和你碰了碰爪"
        case .teaser: return "小窝里响起轻快的脚步声"
        }
    }

    var activityPhrase: String {
        switch self {
        case .stroke: return "摸了摸大橘"
        case .highFive: return "和大橘碰了碰爪"
        case .teaser: return "陪大橘玩了逗猫棒"
        }
    }
}
