import SwiftUI
import PhotosUI
import AVFoundation

/// 聊天页面的 UI 状态管理
@MainActor
@Observable
final class ChatViewModel {
    // MARK: - 输入状态
    var draft = ""
    var isInputFocused = false
    
    // MARK: - 面板状态
    var showStickerPanel = false
    var showFileImporter = false
    var showWallpaperPicker = false
    var showMedia = false
    
    // MARK: - 回复状态
    var replyTarget: ChatMessage?
    
    // MARK: - 图片选择
    var selectedMediaItems: [PhotosPickerItem] = []
    var mediaPreviewItems: [MediaPreviewItem] = []
    var mediaBusy = false
    
    // MARK: - 录音状态
    var isRecording = false
    var recordingCancelled = false
    var recordingElapsed: TimeInterval = 0
    var dragTranslation: CGFloat = 0
    var recordingPulse = false
    
    // 内部录音状态
    var recordingTimer: Timer?
    var audioRecorder: AVAudioRecorder?
    var recordingURL: URL?
    var recordingStartDate: Date?
    var showMicPermissionAlert = false
    
    // MARK: - 滚动状态
    var scrollToMessageId: String?
    var highlightedMessageId: String?
    var pendingTopAnchor: String?
    var isJumping = false
    
    // MARK: - 媒体查看
    var mediaViewerMessageId: String?
    
    // MARK: - 常量
    static let cancelDragThreshold: CGFloat = -70
    static let composerButtonSize: CGFloat = 44
    
    // MARK: - 计算属性
    
    /// 是否有待发送的内容（文字或图片）
    var hasContentToSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mediaPreviewItems.isEmpty
    }
    
    /// 当前应该显示的右侧按钮类型
    var rightButtonType: ComposerRightButton {
        if isRecording {
            return .recording(cancelled: recordingCancelled)
        } else if hasContentToSend {
            return .send
        } else {
            return .voice
        }
    }
    
    // MARK: - 面板切换
    
    func toggleStickerPanel() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if showStickerPanel {
                showStickerPanel = false
            } else {
                isInputFocused = false
                showStickerPanel = true
            }
        }
    }
    
    func dismissAllPanels() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            showStickerPanel = false
        }
    }
    
    // MARK: - 图片预览
    
    func loadMediaPreviewItems() {
        let items = selectedMediaItems
        guard !items.isEmpty else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                mediaPreviewItems = []
            }
            return
        }
        
        mediaBusy = true
        Task {
            var previews: [MediaPreviewItem] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }
                let id = UUID().uuidString
                previews.append(MediaPreviewItem(id: id, image: image, item: item))
            }
            
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                mediaPreviewItems = previews
            }
            mediaBusy = false
        }
    }
    
    func removePreviewItem(_ item: MediaPreviewItem) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            mediaPreviewItems.removeAll { $0.id == item.id }
            selectedMediaItems.removeAll { $0 == item.item }
        }
    }
    
    func clearPreviewItems() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            mediaPreviewItems = []
            selectedMediaItems = []
        }
    }
    
    // MARK: - 回复
    
    func setReplyTarget(_ message: ChatMessage?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            replyTarget = message
        }
    }
    
    func clearReplyTarget() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            replyTarget = nil
        }
    }
}

// MARK: - 输入栏右侧按钮类型

enum ComposerRightButton: Equatable {
    case voice
    case send
    case recording(cancelled: Bool)
    
    var iconName: String {
        switch self {
        case .voice: return "mic"
        case .send: return "arrow.up"
        case .recording(let cancelled): return cancelled ? "trash.fill" : "mic.fill"
        }
    }
    
    var isFilled: Bool {
        switch self {
        case .voice: return false
        case .send: return true
        case .recording(let cancelled): return true
        }
    }
    
    var backgroundColor: Color? {
        switch self {
        case .voice: return nil
        case .send: return DS.Palette.accent
        case .recording(let cancelled): return cancelled ? .red : DS.Palette.accent
        }
    }
}

// MARK: - 图片预览项

struct MediaPreviewItem: Identifiable, Equatable {
    let id: String
    let image: UIImage
    let item: PhotosPickerItem
    
    static func == (lhs: MediaPreviewItem, rhs: MediaPreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}
