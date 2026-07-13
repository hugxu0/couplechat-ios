import Foundation

struct CouplePetSnapshot: Codable, Equatable {
    let pet: CouplePetState
}

struct CouplePetState: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let version: Int
    let level: Int
    let experience: Int
    let satiety: Int
    let cleanliness: Int
    let mood: Int
    let energy: Int
    let coins: Int
    let scene: PetSceneState
    let today: PetDailyPrompt?
    let inventory: [PetCollectible]
    let moments: [PetMoment]
    let latestInteraction: PetInteractionRecord?
    let interactionCooldowns: [PetInteractionCooldown]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "大橘"
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        level = try values.decodeIfPresent(Int.self, forKey: .level) ?? 1
        experience = try values.decodeIfPresent(Int.self, forKey: .experience) ?? 0
        satiety = try values.decodeIfPresent(Int.self, forKey: .satiety) ?? 80
        cleanliness = try values.decodeIfPresent(Int.self, forKey: .cleanliness) ?? 80
        mood = try values.decodeIfPresent(Int.self, forKey: .mood) ?? 80
        energy = try values.decodeIfPresent(Int.self, forKey: .energy) ?? 100
        coins = try values.decodeIfPresent(Int.self, forKey: .coins) ?? 0
        scene = try values.decodeIfPresent(PetSceneState.self, forKey: .scene) ?? .fallback
        today = try values.decodeIfPresent(PetDailyPrompt.self, forKey: .today)
        inventory = try values.decodeIfPresent([PetCollectible].self, forKey: .inventory) ?? []
        moments = try values.decodeIfPresent([PetMoment].self, forKey: .moments) ?? []
        latestInteraction = try values.decodeIfPresent(
            PetInteractionRecord.self, forKey: .latestInteraction)
        interactionCooldowns = try values.decodeIfPresent(
            [PetInteractionCooldown].self, forKey: .interactionCooldowns) ?? []
    }
}

struct PetInteractionCooldown: Codable, Equatable, Identifiable {
    let kind: PetInteractionKind
    let availableAt: Int64

    var id: PetInteractionKind { kind }
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
    case feed
    case bathe
    case play
    case stroke
    case sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed: return "喂食"
        case .bathe: return "洗澡"
        case .play: return "玩耍"
        case .stroke: return "摸摸"
        case .sleep: return "睡觉"
        }
    }

    var systemImage: String {
        switch self {
        case .feed: return "fork.knife"
        case .bathe: return "bathtub.fill"
        case .play: return "tennisball.fill"
        case .stroke: return "hand.raised.fingers.spread"
        case .sleep: return "zzz"
        }
    }

    var confirmation: String {
        switch self {
        case .feed: return "大橘吃得心满意足"
        case .bathe: return "洗得香香的，毛也蓬起来了"
        case .play: return "大橘追着玩具跑了好几圈"
        case .stroke: return "舒服得眯起眼睛了"
        case .sleep: return "大橘蜷成一团睡着了"
        }
    }

    var cooldown: TimeInterval {
        switch self {
        case .feed: return 2 * 60 * 60
        case .bathe: return 12 * 60 * 60
        case .play: return 30 * 60
        case .stroke: return 30
        case .sleep: return 6 * 60 * 60
        }
    }

    func cooldownLabel(remaining: TimeInterval) -> String {
        guard remaining > 0 else { return "可互动" }
        let seconds = Int(ceil(remaining))
        if seconds >= 3_600 {
            return "\(seconds / 3_600)时\((seconds % 3_600) / 60)分"
        }
        return seconds >= 60 ? "\(seconds / 60)分\(seconds % 60)秒" : "\(seconds)秒"
    }

    var activityPhrase: String {
        switch self {
        case .feed: return "给大橘喂了饭"
        case .bathe: return "给大橘洗了澡"
        case .play: return "陪大橘玩了一会儿"
        case .stroke: return "摸了摸大橘"
        case .sleep: return "哄大橘睡着了"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "high_five": self = .stroke
        case "teaser": self = .play
        default:
            guard let value = Self(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown pet interaction kind: \(raw)")
            }
            self = value
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
