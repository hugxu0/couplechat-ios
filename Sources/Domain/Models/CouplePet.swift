import Foundation

struct CouplePetSnapshot: Codable, Equatable {
    let pet: CouplePetState
}

struct CouplePetState: Codable, Equatable, Identifiable {
    let id: String
    let version: Int
    let level: Int
    let experience: Int
    let satiety: Int
    let cleanliness: Int
    let mood: Int
    let energy: Int
    let latestInteraction: PetInteractionRecord?
    let interactionCooldowns: [PetInteractionCooldown]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        level = try values.decodeIfPresent(Int.self, forKey: .level) ?? 1
        experience = try values.decodeIfPresent(Int.self, forKey: .experience) ?? 0
        satiety = try values.decodeIfPresent(Int.self, forKey: .satiety) ?? 80
        cleanliness = try values.decodeIfPresent(Int.self, forKey: .cleanliness) ?? 80
        mood = try values.decodeIfPresent(Int.self, forKey: .mood) ?? 80
        energy = try values.decodeIfPresent(Int.self, forKey: .energy) ?? 100
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
