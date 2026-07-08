import SwiftUI
import AVKit
import AVFoundation

// MARK: - 消息气泡
struct MessageContextPreview: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 5) {
                if let preview = message.replyPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(mine ? .white.opacity(0.74) : DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Text(summary)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 230, alignment: .leading)
            .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            if !mine { Spacer(minLength: 24) }
        }
        .padding(.horizontal, 12)
    }

    private var summary: String {
        switch message.type {
        case "sticker":
            return "[表情]"
        case "image":
            return "[图片]"
        case "video":
            return "[视频]"
        case "file":
            return "[文件]"
        default:
            return message.displayText
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let peerAvatar: String
    var myAvatar: String = "🐶"
    var peerAvatarURL: URL? = nil
    var myAvatarURL: URL? = nil
    let groupedWithPrevious: Bool
    let read: Bool
    let canRetry: Bool
    let highlighted: Bool
    var onRetry: () -> Void = {}
    var onMediaTap: () -> Void = {}
    var contextMenuContent: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                avatarBadge(url: peerAvatarURL, emoji: peerAvatar)
                    .opacity(groupedWithPrevious ? 0 : 1)
            }

            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: 5) {
                    bubbleContentWithMenu
                    if mine { statusIndicator }
                }
                if let confirm = message.meta?.confirm {
                    ActionConfirmCard(messageId: message.id, confirm: confirm)
                        .frame(maxWidth: 280, alignment: mine ? .trailing : .leading)
                }
                if let search = message.meta?.search, !search.items.isEmpty {
                    SearchCitationsCard(items: search.items)
                        .frame(maxWidth: 280, alignment: mine ? .trailing : .leading)
                }
            }

            if mine {
                avatarBadge(url: myAvatarURL, emoji: myAvatar)
                    .opacity(groupedWithPrevious ? 0 : 1)
            }

            if !mine { Spacer(minLength: 60) }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: mine ? .bottomTrailing : .bottomLeading)
                .combined(with: .opacity),
            removal: .opacity))
    }

    @ViewBuilder
    private var bubbleContentWithMenu: some View {
        let hasReply = message.replyPreview != nil && !(message.replyPreview ?? "").isEmpty

        let content = Group {
            if hasReply {
                VStack(alignment: .leading, spacing: 3) {
                    replyPreviewLabel
                    messageCore
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
                .opacity(message.pending ? 0.7 : 1)
            } else {
                messageCore
            }
        }

        let decorated = content
            .messageSearchHighlight(highlighted)

        if let menu = contextMenuContent {
            decorated.contextMenu {
                menu
            } preview: {
                MessageContextPreview(message: message, mine: mine)
            }
        } else {
            decorated
        }
    }

    @ViewBuilder
    private var messageCore: some View {
        switch message.type {
        case "sticker":
            stickerBubble
        case "image":
            imageBubble
        case "video":
            videoBubble
        case "voice":
            voiceBubble
        case "file":
            fileBubble
        default:
            let hasReply = message.replyPreview != nil && !(message.replyPreview ?? "").isEmpty
            Text(message.displayText)
                .font(.system(size: 16))
                .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                .if(!hasReply) {
                    $0.padding(.horizontal, 15)
                      .padding(.vertical, 10)
                      .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                      .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                      .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
                      .opacity(message.pending ? 0.7 : 1)
                }
        }
    }

    private var replyPreviewLabel: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(.white.opacity(mine ? 0.45 : 0.35))
                .frame(width: 2.5, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
            Text(message.replyPreview ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mine ? .white.opacity(0.75) : DS.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// 贴纸：无气泡底、无阴影、固定小尺寸，跟图片区分开
    private var stickerBubble: some View {
        Group {
            if let url = mediaURL {
                CachedImage(url: url, contentMode: .fit) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Palette.bubbleOther.opacity(0.35))
                }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Palette.bubbleOther.opacity(0.35))
            }
        }
        .frame(width: 116, height: 116)
        .opacity(message.pending ? 0.7 : 1)
    }

    private var imageBubble: some View {
        Group {
            if let url = mediaURL {
                RemoteImageBubble(url: url)
            } else {
                mediaFallback("photo", text: message.pending ? "上传中" : "图片")
                    .frame(width: 180, height: 128)
                    .background(DS.Palette.bubbleOther.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .onTapGesture {
            guard !message.pending else { return }
            onMediaTap()
        }
        .opacity(message.pending ? 0.72 : 1)
    }

    private var videoBubble: some View {
        ZStack {
            if let url = mediaURL {
                VideoThumbnailView(url: url)
                    .frame(width: 220, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous)
                    .fill(DS.Palette.bubbleOther.opacity(0.6))
                    .frame(width: 220, height: 132)
            }
            Circle()
                .fill(.black.opacity(0.42))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
            if message.pending {
                VStack(spacing: 6) {
                    Spacer()
                    Text("视频上传中")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.38), in: Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(width: 220, height: 132)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .onTapGesture {
            guard !message.pending else { return }
            onMediaTap()
        }
        .opacity(message.pending ? 0.72 : 1)
    }

    private var voiceBubble: some View {
        Group {
            if let url = mediaURL {
                VoiceBubbleView(url: url, mine: mine)
            } else {
                mediaFallback("mic", text: message.pending ? "上传中" : "语音")
                    .frame(width: 130, height: 20)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
        .opacity(message.pending ? 0.7 : 1)
    }

    private var fileBubble: some View {
        Button {
            guard let mediaURL else { return }
            UIApplication.shared.open(mediaURL)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(mine ? .white : DS.Palette.accent)
                    .frame(width: 34, height: 34)
                    .background(mine ? Color.white.opacity(0.18) : DS.Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                        .lineLimit(1)
                    Text(message.pending ? "上传中" : "点击打开")
                        .font(.system(size: 12))
                        .foregroundStyle(mine ? .white.opacity(0.72) : DS.Palette.textSecondary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(width: 228, alignment: .leading)
            .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            .shadow(color: DS.Surface.shadow, radius: 4, y: 2)
            .opacity(message.pending ? 0.7 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(message.pending || mediaURL == nil)
    }

    private var fileTitle: String {
        let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != "[文件]" { return text }
        if let name = mediaURL?.lastPathComponent, !name.isEmpty { return name }
        return "文件"
    }

    @ViewBuilder
    private func mediaFallback(_ systemName: String, text: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 28))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(DS.Palette.textSecondary)
    }

    private var mediaURL: URL? { message.mediaURL }

    /// 我方消息状态：发送中 → 钟；失败 → 红叹号可点重发；送达 → 单勾；已读 → 主题色双勾
    @ViewBuilder
    private var statusIndicator: some View {
        if message.failed {
            if canRetry {
                Button(action: onRetry) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                }
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
            }
        } else if message.pending {
            ProgressView()
                .controlSize(.mini)
                .tint(DS.Palette.textSecondary)
        } else {
            Image(systemName: read ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(read ? DS.Palette.accent : DS.Palette.textSecondary)
        }
    }

    private func avatarBadge(url: URL?, emoji: String) -> some View {
        AvatarBadge(url: url, fallbackEmoji: emoji, size: 36)
    }
}

struct VoiceBubbleView: View {
    let url: URL
    let mine: Bool

    @State private var player: AVAudioPlayer?
    @State private var delegate: VoicePlaybackDelegate?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var duration: TimeInterval = 0
    @State private var elapsed: TimeInterval = 0
    @State private var progressTimer: Timer?

    private static let barHeights: [CGFloat] = [6, 12, 18, 9, 15, 20, 8, 14, 22, 10, 16, 7, 19, 11, 17, 9, 13, 6]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoading ? "waveform" : (isPlaying ? "pause.fill" : "play.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(mine ? .white : DS.Palette.accent)
                .frame(width: 28, height: 28)
                .background(mine ? Color.white.opacity(0.22) : DS.Palette.accent.opacity(0.15))
                .clipShape(Circle())

            HStack(spacing: 2) {
                ForEach(Array(Self.barHeights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(mine ? Color.white.opacity(0.7) : DS.Palette.accent.opacity(0.55))
                        .frame(width: 2, height: height)
                }
            }
            .frame(height: 22)

            Text(timeLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(mine ? .white.opacity(0.85) : DS.Palette.textSecondary)
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .onTapGesture { togglePlayback() }
        .onDisappear {
            progressTimer?.invalidate()
            player?.stop()
        }
    }

    private var timeLabel: String {
        let value = isPlaying ? max(0, duration - elapsed) : duration
        return String(format: "%d″", max(0, Int(value.rounded())))
    }

    private func togglePlayback() {
        guard !isLoading else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            progressTimer?.invalidate()
            return
        }
        if let player {
            player.play()
            isPlaying = true
            startTimer()
        } else {
            loadAndPlay()
        }
    }

    private func loadAndPlay() {
        isLoading = true
        Task {
            let localURL: URL?
            if url.isFileURL {
                localURL = url
            } else if let (data, _) = try? await URLSession.shared.data(from: url) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
                try? data.write(to: tmp)
                localURL = tmp
            } else {
                localURL = nil
            }
            await MainActor.run {
                isLoading = false
                guard let localURL, let p = try? AVAudioPlayer(contentsOf: localURL) else { return }
                let d = VoicePlaybackDelegate { isPlaying = false; elapsed = 0; progressTimer?.invalidate() }
                p.delegate = d
                p.prepareToPlay()
                delegate = d
                player = p
                duration = p.duration
                p.play()
                isPlaying = true
                startTimer()
            }
        }
    }

    private func startTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                elapsed = player?.currentTime ?? 0
            }
        }
    }
}

private final class VoicePlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }
}

struct RemoteImageBubble: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                let size = Self.fitSize(for: image.size)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            } else if failed {
                VStack(spacing: 7) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                    Text("图片加载失败")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 180, height: 128)
                .background(DS.Palette.bubbleOther.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            } else {
                ProgressView()
                    .tint(DS.Palette.accent)
                    .frame(width: 180, height: 128)
                    .background(DS.Palette.bubbleOther.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            }
        }
        .shadow(color: DS.Surface.shadow.opacity(image == nil ? 0 : 1), radius: 4, y: 2)
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        // 内存命中立刻出图（重复滚动不再抖动）；否则走缓存的后台下载 + 解码
        if let hit = ImageCache.shared.memoryImage(for: url) {
            image = hit
            return
        }
        failed = false
        if let loaded = await ImageCache.shared.image(for: url) {
            image = loaded
        } else {
            failed = true
        }
    }

    private static func fitSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 220, height: 160)
        }
        let maxWidth: CGFloat = 238
        let maxHeight: CGFloat = 320
        let minSide: CGFloat = 96
        let scale = min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1)
        var width = imageSize.width * scale
        var height = imageSize.height * scale
        if min(width, height) < minSide {
            let grow = minSide / min(width, height)
            width *= grow
            height *= grow
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [.black.opacity(0.16), .black.opacity(0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
                return nil
            }
            return UIImage(cgImage: cgImage).preparingForDisplay()
                ?? UIImage(cgImage: cgImage)
        }.value
        thumbnail = image
    }
}

struct MediaPagerView: View {
    let messages: [ChatMessage]
    @Binding var selectedId: String?

    @State private var saving = false
    @State private var toast: String?

    private var selection: Binding<String> {
        Binding(
            get: { selectedId ?? messages.first?.id ?? "" },
            set: { selectedId = $0 }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if messages.isEmpty {
                Text("暂无媒体")
