import Foundation

enum MediaUploadPurpose: String {
    case message
    case album
    case avatar
    case sticker
}

struct MediaUploadResult: Decodable {
    let id: String
    let url: String
    let type: String
}

struct MediaUploadService {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func upload(
        data: Data,
        mimeType: String,
        purpose: MediaUploadPurpose,
        session: Session
    ) async throws -> MediaUploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = authorizedRequest(purpose: purpose, session: session, boundary: boundary)
        request.httpBody = Self.multipartBody(data: data, mimeType: mimeType, boundary: boundary)
        let (responseData, response) = try await httpClient.data(for: request)
        return try decode(responseData, response: response)
    }

    func upload(
        fileURL: URL,
        mimeType: String,
        purpose: MediaUploadPurpose,
        session: Session
    ) async throws -> MediaUploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartURL = try Self.makeMultipartFile(
            mediaURL: fileURL, mimeType: mimeType, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: multipartURL) }
        let request = authorizedRequest(purpose: purpose, session: session, boundary: boundary)
        let (responseData, response) = try await httpClient.upload(for: request, fromFile: multipartURL)
        return try decode(responseData, response: response)
    }

    static func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let filename = "media.\(fileExtension(for: mimeType))"
        body.appendText("--\(boundary)\r\n")
        body.appendText("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendText("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendText("\r\n--\(boundary)--\r\n")
        return body
    }

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case let value where value.contains("video"): return "mp4"
        case let value where value.contains("png"): return "png"
        case let value where value.contains("gif"): return "gif"
        case let value where value.contains("webp"): return "webp"
        case let value where value.contains("audio"): return "m4a"
        case let value where value.contains("pdf"): return "pdf"
        default: return "jpg"
        }
    }

    private func authorizedRequest(
        purpose: MediaUploadPurpose,
        session: Session,
        boundary: String
    ) -> URLRequest {
        let base = ServerConfig.baseURL.appendingPathComponent("api/upload")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "purpose", value: purpose.rawValue)]
        var request = URLRequest(url: components?.url ?? base)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func decode(_ data: Data, response: URLResponse) throws -> MediaUploadResult {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            let message = ServerErrorCode.message(for: code, fallback: "上传失败")
            throw NSError(
                domain: "upload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(MediaUploadResult.self, from: data)
    }

    private static func makeMultipartFile(
        mediaURL: URL,
        mimeType: String,
        boundary: String
    ) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw NSError(
                domain: "upload",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建上传临时文件"])
        }
        let input = try FileHandle(forReadingFrom: mediaURL)
        let output = try FileHandle(forWritingTo: outputURL)
        do {
            let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(mediaURL.lastPathComponent)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            while let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try input.close()
            try output.close()
            return outputURL
        } catch {
            try? input.close()
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}

private extension Data {
    mutating func appendText(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
