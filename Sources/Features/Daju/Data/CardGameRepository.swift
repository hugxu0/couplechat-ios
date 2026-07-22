import Foundation

enum CardGameRarity: String, Codable, CaseIterable, Hashable {
    case common
    case rare
    case epic
    case legendary

    var title: String {
        switch self {
        case .common: return "普通"
        case .rare: return "稀有"
        case .epic: return "史诗"
        case .legendary: return "传说"
        }
    }
}

enum CardGameCategory: String, Codable, CaseIterable, Hashable {
    case intimacy
    case money
    case emotion
    case choice
    case support

    var title: String {
        switch self {
        case .intimacy: return "亲密卡"
        case .money: return "红包卡"
        case .emotion: return "情绪卡"
        case .choice: return "选择权卡"
        case .support: return "辅助卡"
        }
    }
}

struct CardGameDefinition: Codable, Hashable, Identifiable {
    let key: String
    let title: String
    let category: CardGameCategory
    let rarity: CardGameRarity
    let summary: String
    let icon: String
    let effectKind: String
    let durationMs: Int64?
    let modifier: String?

    var id: String { "\(key):\(rarity.rawValue)" }
    var isModifier: Bool { modifier != nil }
}

struct CardGameInventoryItem: Codable, Hashable, Identifiable {
    let id: String
    let cardKey: String
    let rarity: CardGameRarity
    let quantity: Int

    var definitionID: String { "\(cardKey):\(rarity.rawValue)" }
}

struct CardGameEffect: Codable, Hashable, Identifiable {
    let id: String
    let cardKey: String
    let title: String
    let rarity: CardGameRarity
    let summary: String
    let effectKind: String
    let senderUsername: String
    let senderName: String
    let targetUsername: String
    let targetName: String
    let startsAt: Int64
    let expiresAt: Int64?
    let status: String
    let payload: [String: JSONValue]
    let createdAt: Int64
}

/// 卡片 payload 只用于展示被复制/修改的对象；用一个宽松值类型避免服务端
/// 将来新增字段时让整个卡牌快照无法解码。
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct CardGameSnapshot: Codable {
    let day: String
    let now: Int64
    let drawsUsed: Int
    let drawsRemaining: Int
    let inventory: [CardGameInventoryItem]
    let partnerInventory: [CardGameInventoryItem]
    let activeEffects: [CardGameEffect]
    let recentEffects: [CardGameEffect]
    let catalog: [CardGameDefinition]

    func definition(for item: CardGameInventoryItem) -> CardGameDefinition? {
        catalog.first { $0.key == item.cardKey && $0.rarity == item.rarity }
    }

    func definition(for effect: CardGameEffect) -> CardGameDefinition? {
        catalog.first { $0.key == effect.cardKey && $0.rarity == effect.rarity }
    }
}

struct CardGameDraw: Codable {
    let success: Bool
    let card: CardGameDefinition?
}

struct CardGameDrawResult {
    let snapshot: CardGameSnapshot
    let draw: CardGameDraw
}

struct CardGameUseResult {
    let snapshot: CardGameSnapshot
    let effect: CardGameEffect
}

struct CardGameRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(token: String) async throws -> CardGameSnapshot {
        let request = try makeRequest(path: "api/v2/card-game", token: token)
        let response: SnapshotResponse = try await perform(request)
        return response.game
    }

    func draw(token: String, idempotencyKey: String = UUID().uuidString) async throws -> CardGameDrawResult {
        let body = DrawBody(idempotencyKey: idempotencyKey)
        let request = try makeRequest(path: "api/v2/card-game/draw", method: "POST", body: body, token: token)
        let response: DrawResponse = try await perform(request)
        return CardGameDrawResult(snapshot: response.game, draw: response.draw)
    }

    func use(
        token: String,
        cardKey: String,
        rarity: CardGameRarity,
        effectID: String? = nil,
        sourceCardKey: String? = nil,
        sourceRarity: CardGameRarity? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> CardGameUseResult {
        let body = UseBody(
            cardKey: cardKey,
            rarity: rarity,
            idempotencyKey: idempotencyKey,
            effectId: effectID,
            sourceCardKey: sourceCardKey,
            sourceRarity: sourceRarity)
        let request = try makeRequest(path: "api/v2/card-game/use", method: "POST", body: body, token: token)
        let response: UseResponse = try await perform(request)
        return CardGameUseResult(snapshot: response.game, effect: response.effect)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        token: String
    ) throws -> URLRequest {
        guard let request = APIRequestFactory.authorized(
            path: path,
            method: method,
            token: token,
            timeout: 20) else {
            throw CardGameRepositoryError.invalidRequest
        }
        return request
    }

    private func makeRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        token: String
    ) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CardGameRepositoryError.invalidResponse
        }
        if http.statusCode == 401 { throw CardGameRepositoryError.unauthorized }
        let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
        guard (200..<300).contains(http.statusCode) else {
            throw CardGameRepositoryError.server(code ?? "request_failed")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CardGameRepositoryError.invalidResponse
        }
    }

    private struct SnapshotResponse: Decodable { let game: CardGameSnapshot }
    private struct DrawResponse: Decodable { let game: CardGameSnapshot; let draw: CardGameDraw }
    private struct UseResponse: Decodable { let game: CardGameSnapshot; let effect: CardGameEffect }
    private struct ErrorResponse: Decodable { let error: String }

    private struct DrawBody: Encodable { let idempotencyKey: String }
    private struct UseBody: Encodable {
        let cardKey: String
        let rarity: CardGameRarity
        let idempotencyKey: String
        let effectId: String?
        let sourceCardKey: String?
        let sourceRarity: CardGameRarity?
    }
}

enum CardGameRepositoryError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "卡牌请求参数无效"
        case .invalidResponse: return "卡牌数据暂时无法识别"
        case .unauthorized: return "登录已失效，请重新登录"
        case let .server(code):
            return Self.message(for: code)
        }
    }

    private static func message(for code: String) -> String {
        switch code {
        case "couple_required": return "需要先建立情侣关系"
        case "draw_limit_reached": return "今天的三次抽卡机会已经用完"
        case "card_not_owned": return "这张卡已经用过了，或不在你的卡库里"
        case "source_card_not_found": return "对方卡库里找不到可复制的卡"
        case "effect_required": return "请选择一个正在生效的目标"
        case "effect_not_active": return "这项效果已经结束"
        case "effect_not_owned": return "这项效果目前不对你生效"
        default: return "卡牌操作暂时失败（\(code)）"
        }
    }
}
