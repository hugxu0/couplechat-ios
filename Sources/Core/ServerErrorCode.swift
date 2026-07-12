import Foundation

enum ServerErrorCode: String, Decodable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case invalidCredentials = "invalid_credentials"
    case notFound = "not_found"
    case uploadsDisabled = "uploads_disabled"
    case fileRequired = "file_required"
    case unsupportedMediaType = "unsupported_media_type"
    case fileSignatureMismatch = "file_signature_mismatch"
    case uploadNotFound = "upload_not_found"
    case uploadAlreadyAttached = "upload_already_attached"
    case uploadURLMismatch = "upload_url_mismatch"
    case attachmentPhotoTypeMismatch = "attachment_photo_type_mismatch"
    case attachmentVideoTypeMismatch = "attachment_video_type_mismatch"
    case internalError = "internal_error"

    var actionableMessage: String {
        switch self {
        case .invalidRequest: return "请求内容无效，请重试"
        case .unauthorized: return "登录已过期，请重新登录"
        case .invalidCredentials: return "用户名或密码不对"
        case .notFound: return "内容已不存在，请刷新后重试"
        case .uploadsDisabled: return "服务器暂时不能接收文件，请稍后重试"
        case .fileRequired: return "没有读取到文件，请重新选择"
        case .unsupportedMediaType: return "暂不支持这种文件格式"
        case .fileSignatureMismatch: return "文件内容与格式不一致，请重新选择原文件"
        case .uploadNotFound: return "上传记录已失效，请重新选择文件发送"
        case .uploadAlreadyAttached: return "文件已经发送过，请重新选择后发送"
        case .uploadURLMismatch: return "上传信息不一致，请重新上传"
        case .attachmentPhotoTypeMismatch: return "照片格式不正确，请重新选择"
        case .attachmentVideoTypeMismatch: return "实况视频格式不正确，请重新选择"
        case .internalError: return "服务器暂时出错，请稍后重试"
        }
    }

    static func message(for rawValue: String?, fallback: String) -> String {
        guard let rawValue, let code = ServerErrorCode(rawValue: rawValue) else { return fallback }
        return code.actionableMessage
    }
}
