import Foundation

enum V2RepositoryError: LocalizedError, Equatable {
    case invalidRequest
    case server(Int)
    case invalidResponse
    case albumConflict(MomentAlbum)
    case calendarConflict(CalendarEvent)
    case transcriptConflict(VoiceTranscript)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "请求地址无效"
        case .server(let code): return "服务暂时不可用（\(code)）"
        case .invalidResponse: return "服务器返回了无法识别的数据"
        case .albumConflict: return "相册已在另一台设备更新，已载入最新版本"
        case .calendarConflict: return "日程已在另一台设备更新，已载入最新版本"
        case .transcriptConflict: return "转写已在另一台设备更新，已载入最新版本"
        }
    }
}

struct MomentsRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func albums(cursor: String? = nil, limit: Int = 20, token: String) async throws -> MomentPage<MomentAlbum> {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(path: "api/v2/albums", query: query, token: token)
        let payload = try JSONDecoder().decode(AlbumsEnvelope.self, from: data)
        return MomentPage(values: payload.albums ?? [], nextCursor: payload.nextCursor)
    }

    func onThisDay(token: String) async throws -> [OnThisDayMoment] {
        var assets: [MomentAsset] = []
        var cursor: String?
        var stableDate: String?
        var pageCount = 0
        repeat {
            var query = [
                URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
                URLQueryItem(name: "limit", value: "100"),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            if let stableDate { query.append(URLQueryItem(name: "date", value: stableDate)) }
            let data = try await request(
                path: "api/v2/media/on-this-day", query: query, token: token)
            let payload = try JSONDecoder().decode(OnThisDayEnvelope.self, from: data)
            stableDate = payload.date
            assets.append(contentsOf: payload.assets)
            cursor = payload.hasMore ? payload.nextCursor : nil
            pageCount += 1
        } while cursor != nil && pageCount < 100
        let currentYear = Calendar.current.component(.year, from: Date())
        let grouped = Dictionary(grouping: assets) { asset in
            max(1, currentYear - Calendar.current.component(.year, from: asset.date))
        }
        return grouped.keys.sorted().compactMap { yearsAgo in
            guard let assets = grouped[yearsAgo], !assets.isEmpty else { return nil }
            return OnThisDayMoment(
                id: "\(stableDate ?? "today")-\(yearsAgo)",
                yearsAgo: yearsAgo,
                title: "\(yearsAgo) 年前的今天",
                date: stableDate ?? "",
                assets: assets)
        }
    }

    func createAlbum(title: String, note: String?, token: String) async throws -> MomentAlbum {
        let body = AlbumMutation(title: title, summary: note ?? "")
        let data = try await request(path: "api/v2/albums", method: "POST", body: body, token: token)
        return try JSONDecoder().decode(AlbumEnvelope.self, from: data).album
    }

    func album(id: String, cursor: String? = nil, limit: Int = 40, token: String) async throws -> (MomentAlbum, MomentPage<MomentAsset>) {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(path: "api/v2/albums/\(id)/items", query: query, token: token)
        let payload = try JSONDecoder().decode(AlbumDetailEnvelope.self, from: data)
        return (payload.album, MomentPage(values: payload.assets ?? payload.items ?? [], nextCursor: payload.nextCursor))
    }

    func addMessage(
        albumId: String,
        messageId: String,
        attachmentId: String? = nil,
        token: String
    ) async throws -> [MomentAsset] {
        let body = AddMessageMutation(messageId: messageId)
        let data = try await request(
            path: "api/v2/albums/\(albumId)/items/from-message", method: "POST", body: body, token: token)
        return try JSONDecoder().decode(AddedEnvelope.self, from: data).added.map(\.displayAsset)
    }

    func addUpload(
        albumId: String,
        uploadId: String,
        takenAt: Int,
        token: String
    ) async throws -> [MomentAsset] {
        let body = AddUploadMutation(uploadId: uploadId, takenAt: takenAt)
        let data = try await request(
            path: "api/v2/albums/\(albumId)/items/from-upload",
            method: "POST",
            body: body,
            token: token)
        return try JSONDecoder().decode(AddedEnvelope.self, from: data).added.map(\.displayAsset)
    }

    func updateCaption(
        assetId: String,
        text: String,
        baseVersion: Int?,
        token: String
    ) async throws -> MomentNote {
        let data = try await request(
            path: "api/v2/media-assets/\(assetId)/note",
            method: "PATCH",
            body: NoteMutation(text: text, baseVersion: baseVersion),
            token: token)
        return try JSONDecoder().decode(NoteEnvelope.self, from: data).note
    }

    func updateAlbum(_ album: MomentAlbum, title: String, summary: String, token: String) async throws -> MomentAlbum {
        let mutation = AlbumPatch(title: title, summary: summary, baseVersion: album.version)
        let data = try await request(
            path: "api/v2/albums/\(album.id)", method: "PATCH", body: mutation, token: token)
        return try JSONDecoder().decode(AlbumEnvelope.self, from: data).album
    }

    func deleteAlbum(_ album: MomentAlbum, token: String) async throws {
        _ = try await request(
            path: "api/v2/albums/\(album.id)", method: "DELETE",
            body: VersionMutation(baseVersion: album.version), token: token)
    }

    func removeItem(albumId: String, itemId: String, token: String) async throws {
        _ = try await request(
            path: "api/v2/albums/\(albumId)/items/\(itemId)", method: "DELETE", token: token)
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        token: String
    ) async throws -> Data {
        try await request(path: path, query: query, method: method, bodyData: nil, token: token)
    }

    private func request<Body: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        method: String,
        body: Body,
        token: String
    ) async throws -> Data {
        try await request(
            path: path, query: query, method: method,
            bodyData: try JSONEncoder().encode(body), token: token)
    }

    private func request(
        path: String,
        query: [URLQueryItem],
        method: String,
        bodyData: Data?,
        token: String
    ) async throws -> Data {
        guard let base = URL(string: path, relativeTo: ServerConfig.baseURL),
              var components = URLComponents(url: base.absoluteURL, resolvingAgainstBaseURL: true) else {
            throw V2RepositoryError.invalidRequest
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw V2RepositoryError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if bodyData != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await httpClient.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw V2RepositoryError.invalidResponse
        }
        if code == 409,
           let conflict = try? JSONDecoder().decode(AlbumConflictEnvelope.self, from: data) {
            throw V2RepositoryError.albumConflict(conflict.album)
        }
        guard (200..<300).contains(code) else { throw V2RepositoryError.server(code) }
        return data
    }
}

private extension MomentsRepository {
    struct AlbumsEnvelope: Decodable {
        let albums: [MomentAlbum]?
        let nextCursor: String?
        let hasMore: Bool?
    }
    struct OnThisDayEnvelope: Decodable {
        let date: String
        let timezone: String
        let assets: [MomentAsset]
        let nextCursor: String?
        let hasMore: Bool
    }
    struct AlbumEnvelope: Decodable { let album: MomentAlbum }
    struct AlbumConflictEnvelope: Decodable { let album: MomentAlbum }
    struct AlbumDetailEnvelope: Decodable {
        let album: MomentAlbum
        let assets: [MomentAsset]?
        let items: [MomentAsset]?
        let nextCursor: String?
    }
    struct AddedEnvelope: Decodable { let added: [AddedItem] }
    struct AddedItem: Decodable {
        let itemId: String
        let asset: MomentAsset
        var displayAsset: MomentAsset {
            MomentAsset(
                id: asset.id, albumItemId: itemId, messageId: asset.messageId,
                attachmentId: asset.attachmentId, mediaType: asset.mediaType,
                url: asset.url, thumbnailURL: asset.thumbnailURL, caption: asset.caption,
                noteVersion: asset.noteVersion, addedBy: asset.addedBy,
                takenAt: asset.takenAt, version: asset.version)
        }
    }
    struct NoteEnvelope: Decodable { let note: MomentNote }
    struct AlbumMutation: Encodable { let title: String; let summary: String }
    struct AlbumPatch: Encodable { let title: String; let summary: String; let baseVersion: Int }
    struct AddMessageMutation: Encodable { let messageId: String }
    struct AddUploadMutation: Encodable { let uploadId: String; let takenAt: Int }
    struct NoteMutation: Encodable { let text: String; let baseVersion: Int? }
    struct VersionMutation: Encodable { let baseVersion: Int }
}

private extension MomentAsset {
    var date: Date { Date(timeIntervalSince1970: Double(takenAt) / 1_000) }
}
