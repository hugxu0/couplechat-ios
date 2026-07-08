import Foundation
import UIKit

/// 媒体服务：处理文件上传
@MainActor
final class MediaService: ObservableObject {
    static let baseURL = ServerConfig.baseURL
    
    var session: Session?
    
    struct UploadResponse: Decodable {
        let url: String
        let type: String
    }
    
    // MARK: - 上传
    
    func uploadMedia(data: Data, mimeType: String) async throws -> UploadResponse {
        guard let token = session?.token else {
            throw NSError(domain: "upload", code: 401, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/upload"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartBody(data: data, mimeType: mimeType, boundary: boundary)
        
        let (responseData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: responseData))?["error"]
            throw NSError(domain: "upload", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "上传失败"])
        }
        
        return try JSONDecoder().decode(UploadResponse.self, from: responseData)
    }
    
    /// 上传一张自定义贴纸，返回远程地址
    func uploadSticker(_ image: UIImage) async -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        guard let uploaded = try? await uploadMedia(data: data, mimeType: "image/jpeg") else { return nil }
        
        if let url = ServerConfig.resolveMediaURL(uploaded.url) {
            ImageCache.shared.store(data: data, image: image, for: url)
        }
        
        return uploaded.url
    }
    
    /// 上传用户头像
    func uploadAvatar(_ image: UIImage) async -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        guard let uploaded = try? await uploadMedia(data: data, mimeType: "image/jpeg") else { return false }
        
        // 先把刚上传的图塞进缓存
        if let url = ServerConfig.resolveMediaURL(uploaded.url) {
            ImageCache.shared.store(data: data, image: image, for: url)
        }
        
        return true
    }
    
    // MARK: - 辅助
    
    private func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let filename: String
        
        if mimeType.contains("video") {
            filename = "media.mp4"
        } else if mimeType.contains("audio") {
            filename = "media.m4a"
        } else {
            filename = "media.jpg"
        }
        
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
