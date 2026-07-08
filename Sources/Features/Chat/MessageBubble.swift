import SwiftUI
import AVFoundation

// MARK: - 娑堟伅姘旀场
private struct MessageContextPreview: View {
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
            return "[琛ㄦ儏]"
        case "image":
            return "[鍥剧墖]"
        case "video":
            return "[瑙嗛]"
        case "file":
            return "[鏂囦欢]"
        default:
            return message.displayText
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let peerAvatar: String
    var myAvatar: String = "馃惗"
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

    /// 璐寸焊锛氭棤姘旀场搴曘€佹棤闃村奖銆佸浐瀹氬皬灏哄锛岃窡鍥剧墖鍖哄垎寮€
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
                mediaFallback("photo", text: message.pending ? "涓婁紶涓? : "鍥剧墖")
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
                    Text("瑙嗛涓婁紶涓?)
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
                mediaFallback("mic", text: message.pending ? "涓婁紶涓? : "璇煶")
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
                    Text(message.pending ? "涓婁紶涓? : "鐐瑰嚮鎵撳紑")
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
        if !text.isEmpty && text != "[鏂囦欢]" { return text }
        if let name = mediaURL?.lastPathComponent, !name.isEmpty { return name }
        return "鏂囦欢"
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

    /// 鎴戞柟娑堟伅鐘舵€侊細鍙戦€佷腑 鈫?閽燂紱澶辫触 鈫?绾㈠徆鍙峰彲鐐归噸鍙戯紱閫佽揪 鈫?鍗曞嬀锛涘凡璇?鈫?涓婚鑹插弻鍕?    @ViewBuilder
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

private struct VoiceBubbleView: View {
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
        return String(format: "%d鈥?, max(0, Int(value.rounded())))
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

private struct RemoteImageBubble: View {
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
                    Text("鍥剧墖鍔犺浇澶辫触")
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
        // 鍐呭瓨鍛戒腑绔嬪埢鍑哄浘锛堥噸澶嶆粴鍔ㄤ笉鍐嶆姈鍔級锛涘惁鍒欒蛋缂撳瓨鐨勫悗鍙颁笅杞?+ 瑙ｇ爜
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

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }

    func messageSearchHighlight(_ highlighted: Bool) -> some View {
        self
            .overlay {
                if highlighted {
                    RoundedRectangle(cornerRadius: DS.Radius.bubble + 5, style: .continuous)
                        .stroke(DS.Palette.accent.opacity(0.9), lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.bubble + 5, style: .continuous)
                                .fill(DS.Palette.accent.opacity(0.14))
                        )
                        .padding(-5)
                }
            }
            .shadow(color: highlighted ? DS.Palette.accent.opacity(0.28) : .clear, radius: 12, y: 2)
    }
}

private struct ActionConfirmCard: View {
    @EnvironmentObject private var store: ChatStore
    let messageId: String
    let confirm: ActionConfirm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(confirm.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: item.action.type))
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text(item.label)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if confirm.status == "pending" {
                HStack(spacing: 10) {
                    Button {
                        store.confirmAction(messageId: messageId, decision: "confirm")
                    } label: {
                        Text("纭")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(DS.Palette.accent, in: Capsule())
                    }
                    Button {
                        store.confirmAction(messageId: messageId, decision: "cancel")
                    } label: {
                        Text("鍙栨秷")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(DS.Palette.bubbleOther, in: Capsule())
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: confirm.status == "confirmed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(confirm.status == "confirmed" ? DS.Palette.green : DS.Palette.textSecondary)
                    Text(confirm.status == "confirmed" ? "宸茬‘璁? : "宸插彇娑?)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .padding(12)
        .background(DS.Palette.bubbleOther.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.Palette.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func iconName(for type: String) -> String {
        switch type {
        case "add_reminder": return "bell.badge"
        case "add_memo": return "note.text"
        case "complete_reminder": return "checkmark.circle"
        case "delete_reminder": return "trash"
        case "edit_memo": return "pencil.line"
        default: return "pawprint"
        }
    }
}

private struct SearchCitationsCard: View {
    let items: [SearchCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                Text("鏉ユ簮")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.Palette.textSecondary)

            ForEach(items) { item in
                if let url = URL(string: item.url) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DS.Palette.accent)
                                .lineLimit(2)
                            Text(item.url)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(DS.Palette.bubbleOther.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
