import Foundation

enum ServerErrorCode: String, Decodable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case invalidCredentials = "invalid_credentials"
    case notFound = "not_found"
    case recallWindowExpired = "recall_window_expired"
    case memoryVersionConflict = "memory_version_conflict"
    case memoryNotFound = "memory_not_found"
    case memoryTenantRefreshPending = "memory_tenant_refresh_pending"
    case usernameTaken = "username_taken"
    case alreadyPaired = "already_paired"
    case coupleRequired = "couple_required"
    case coupleFull = "couple_full"
    case inviteInvalid = "invite_invalid"
    case deviceSessionRequired = "device_session_required"
    case deviceNotFound = "device_not_found"
    case accountNotFound = "account_not_found"
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
        case .recallWindowExpired: return "消息发送超过 2 分钟，已经不能撤回"
        case .memoryVersionConflict: return "这条 Memory 已在另一台设备更新，请刷新后再编辑"
        case .memoryNotFound: return "这条 Memory 已被删除或不再可用"
        case .memoryTenantRefreshPending: return "当前配对的 Memory 重建尚未开放"
        case .usernameTaken: return "这个用户名已经被使用"
        case .alreadyPaired: return "当前账号已经完成配对"
        case .coupleRequired: return "请先完成情侣配对，再使用共享功能"
        case .coupleFull: return "这个配对已经有两位成员"
        case .inviteInvalid: return "配对邀请码无效或已经失效"
        case .deviceSessionRequired: return "设备登录信息已失效，请重新登录"
        case .deviceNotFound: return "这台设备已退出登录，请重新登录"
        case .accountNotFound: return "账号不存在或已停用"
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
