import Foundation
import ImageIO
import UniformTypeIdentifiers

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

enum MediaUploadError: LocalizedError {
    case rejected(message: String, retryable: Bool)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .rejected(message, _): return message
        case .invalidResponse: return "上传响应无效"
        }
    }

    var isRetryable: Bool {
        switch self {
        case let .rejected(_, retryable): return retryable
        case .invalidResponse: return false
        }
    }
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
        request.httpBody = await Task.detached(priority: .utility) {
            Self.multipartBody(data: data, mimeType: mimeType, boundary: boundary)
        }.value
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
        let multipartURL = try await Task.detached(priority: .utility) {
            try Self.makeMultipartFile(
                mediaURL: fileURL, mimeType: mimeType, boundary: boundary)
        }.value
        defer { try? FileManager.default.removeItem(at: multipartURL) }
        let request = authorizedRequest(purpose: purpose, session: session, boundary: boundary)
        let (responseData, response) = try await httpClient.upload(for: request, fromFile: multipartURL)
        return try decode(responseData, response: response)
    }

    static func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        appendThumbnailField(
            thumbnailJPEG(data: data, mimeType: mimeType),
            boundary: boundary,
            to: &body)
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
        request.timeoutInterval = 90
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func decode(_ data: Data, response: URLResponse) throws -> MediaUploadResult {
        guard let http = response as? HTTPURLResponse else {
            throw MediaUploadError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            let message = ServerErrorCode.message(for: code, fallback: "上传失败")
            let retryable = http.statusCode == 408
                || http.statusCode == 429
                || (500..<600).contains(http.statusCode)
            throw MediaUploadError.rejected(message: message, retryable: retryable)
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
            if let thumbnail = thumbnailJPEG(fileURL: mediaURL, mimeType: mimeType) {
                let thumbnailHeader = "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"thumbnailBase64\"\r\n"
                    + "Content-Type: text/plain; charset=us-ascii\r\n\r\n"
                try output.write(contentsOf: Data(thumbnailHeader.utf8))
                try output.write(contentsOf: thumbnail.base64EncodedData())
                try output.write(contentsOf: Data("\r\n".utf8))
            }
            let header = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; "
                + "filename=\"\(mediaURL.lastPathComponent)\"\r\n"
                + "Content-Type: \(mimeType)\r\n\r\n"
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

    private static let thumbnailMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/webp", "image/heic", "image/heif",
    ]
    private static let maxThumbnailBytes = 512 * 1_024

    private static func appendThumbnailField(
        _ thumbnail: Data?,
        boundary: String,
        to body: inout Data
    ) {
        guard let thumbnail else { return }
        body.appendText("--\(boundary)\r\n")
        body.appendText("Content-Disposition: form-data; name=\"thumbnailBase64\"\r\n")
        body.appendText("Content-Type: text/plain; charset=us-ascii\r\n\r\n")
        body.append(thumbnail.base64EncodedData())
        body.appendText("\r\n")
    }

    private static func thumbnailJPEG(data: Data, mimeType: String) -> Data? {
        guard thumbnailMIMETypes.contains(mimeType.lowercased()),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnailJPEG(source: source, mimeType: mimeType)
    }

    private static func thumbnailJPEG(fileURL: URL, mimeType: String) -> Data? {
        guard thumbnailMIMETypes.contains(mimeType.lowercased()),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return thumbnailJPEG(source: source, mimeType: mimeType)
    }

    private static func thumbnailJPEG(source: CGImageSource, mimeType: String) -> Data? {
        let normalizedMIMEType = mimeType.lowercased()
        if (normalizedMIMEType == "image/png" || normalizedMIMEType == "image/webp"),
           CGImageSourceGetCount(source) > 1 {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let data = output as Data
        guard data.count <= maxThumbnailBytes else { return nil }
        return data
    }
}

private extension Data {
    mutating func appendText(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
