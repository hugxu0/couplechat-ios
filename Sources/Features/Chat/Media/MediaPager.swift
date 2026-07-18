import SwiftUI
import AVKit
import AVFoundation
import UIKit
import Photos
import Combine

/// 沉浸式媒体浏览：不显示页码或工具栏，操作只在手势和长按菜单中出现。
struct MediaPagerView: View {
    let items: [MediaBrowserItem]
    @Binding var selectedId: String?
    var showsBackdrop = true
    var onZoomScaleChange: (CGFloat) -> Void = { _ in }

    @EnvironmentObject private var favorites: MediaFavoriteStore
    @State private var saving = false
    @State private var toast: String?

    init(
        messages: [ChatMessage],
        selectedId: Binding<String?>,
        showsBackdrop: Bool = true,
        onZoomScaleChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.items = messages.flatMap(MediaBrowserItem.items(for:))
        _selectedId = selectedId
        self.showsBackdrop = showsBackdrop
        self.onZoomScaleChange = onZoomScaleChange
    }

    init(
        items: [MediaBrowserItem],
        selectedId: Binding<String?>,
        showsBackdrop: Bool = true,
        onZoomScaleChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.items = items
        _selectedId = selectedId
        self.showsBackdrop = showsBackdrop
        self.onZoomScaleChange = onZoomScaleChange
    }

    private var selectedIndex: Int {
        guard let selectedId,
              let index = items.firstIndex(where: { $0.id == selectedId }) else { return 0 }
        return index
    }

    private var selection: Binding<String> {
        Binding(
            get: { selectedId ?? items.first?.id ?? "" },
            set: { selectedId = $0 }
        )
    }

    var body: some View {
        ZStack {
            if showsBackdrop {
                Color.black
                    .ignoresSafeArea()
            }

            if items.isEmpty {
                Text("暂无媒体")
                    .font(DS.Typo.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                // 保持稳定的完整页序列；之前在手势中动态增删相邻页，会让 PageViewController
                // 丢失当前索引，从而卡在两张图之间。图片加载由缓存和预取负责。
                TabView(selection: selection) {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        MediaPage(
                            item: item,
                            // 仅保留当前页与相邻页；避免一次打开同时下载多张 50 MiB 原图。
                            shouldLoadMedia: abs(index - selectedIndex) <= 1,
                            isFavorite: favorites.contains(item),
                            onSave: { save(item) },
                            onToggleFavorite: { toggleFavorite(item) },
                            onZoomScaleChange: onZoomScaleChange
                        )
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(DS.Typo.secondary.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 42)
                }
                .transition(.opacity)
            }

        }
        .background(Color.clear)
        .accessibilityAction(.escape) { selectedId = nil }
        .preferredColorScheme(.dark)
    }

    private func save(_ item: MediaBrowserItem) {
        guard let url = item.mediaURL, !saving else { return }
        saving = true
        Task {
            let success: Bool
            if item.isVideo {
                success = await MediaSaver.saveVideo(from: url)
            } else {
                success = await MediaSaver.saveImage(from: url)
            }
            await MainActor.run {
                saving = false
                showToast(success ? "已保存到相册" : "保存失败")
            }
        }
    }

    private func toggleFavorite(_ item: MediaBrowserItem) {
        let added = favorites.toggle(item)
        Haptics.light()
        showToast(added ? "已收藏" : "已取消收藏")
    }

    private func showToast(_ text: String) {
        withAnimation(DS.Anim.ease) {
            toast = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            guard toast == text else { return }
            withAnimation(DS.Anim.ease) {
                toast = nil
            }
        }
    }
}

private struct MediaPage: View {
    let item: MediaBrowserItem
    let shouldLoadMedia: Bool
    let isFavorite: Bool
    let onSave: () -> Void
    let onToggleFavorite: () -> Void
    let onZoomScaleChange: (CGFloat) -> Void
    @State private var imageSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if item.isVideo, let url = item.mediaURL, shouldLoadMedia {
                    MediaViewerVideoPage(url: url)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let url = item.mediaURL, shouldLoadMedia {
                    ZoomableRemoteImage(
                        url: url,
                        size: geometry.size,
                        onScaleChange: onZoomScaleChange,
                        onImageSizeChange: { value in
                            guard value.width > 0, value.height > 0 else { return }
                            imageSize = value
                        })
                } else if item.mediaURL != nil {
                    ProgressView().tint(.white.opacity(0.7))
                } else {
                    failedView
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay {
                let targetSize = transitionMediaSize(in: geometry.size)
                MediaViewerTransitionTarget(identifier: item.id)
                    .frame(width: targetSize.width, height: targetSize.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            // 使用真实媒体作为系统上下文预览；UIKit 负责长按时的缩放和菜单转场。
            .contextMenu(menuItems: {
                Button {
                    onSave()
                } label: {
                    Label("下载", systemImage: "arrow.down.to.line")
                }
                Button {
                    onToggleFavorite()
                } label: {
                    Label(isFavorite ? "取消收藏" : "收藏", systemImage: isFavorite ? "heart.slash" : "heart")
                }
            }, preview: { mediaContextPreview(in: geometry.size) })
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func mediaContextPreview(in size: CGSize) -> some View {
        let previewWidth = min(size.width * 0.82, 340)
        let previewHeight = min(size.height * 0.62, 460)
        if item.isVideo, let url = item.mediaURL {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(width: previewWidth, height: previewHeight)
                .background(.black)
        } else if let url = item.mediaURL {
            CachedImage(url: url, contentMode: .fit) {
                ProgressView().tint(.white)
            }
            .frame(width: previewWidth, height: previewHeight)
            .background(.black)
        } else {
            failedView
                .frame(width: previewWidth, height: previewHeight)
                .background(.black)
        }
    }

    private var failedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
            Text("加载失败")
                .font(DS.Typo.secondary.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.72))
    }

    private func transitionMediaSize(in container: CGSize) -> CGSize {
        guard !item.isVideo,
              let imageSize,
              imageSize.width > 0,
              imageSize.height > 0,
              container.width > 0,
              container.height > 0 else {
            return container
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

final class MediaViewerTransitionTargetView: UIView {
    var mediaIdentifier = ""
}

private struct MediaViewerTransitionTarget: UIViewRepresentable {
    let identifier: String

    func makeUIView(context: Context) -> MediaViewerTransitionTargetView {
        let view = MediaViewerTransitionTargetView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MediaViewerTransitionTargetView, context: Context) {
        view.mediaIdentifier = identifier
    }
}

private struct ZoomableRemoteImage: View {
    let url: URL
    let size: CGSize
    let onScaleChange: (CGFloat) -> Void
    let onImageSizeChange: (CGSize) -> Void

    @State private var settledScale: CGFloat = 1
    @State private var settledOffset: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    private var scale: CGFloat {
        min(4, max(1, settledScale * magnification))
    }

    private var offset: CGSize {
        guard scale > 1 else { return .zero }
        return clampedOffset(CGSize(
            width: settledOffset.width + dragTranslation.width,
            height: settledOffset.height + dragTranslation.height))
    }

    var body: some View {
        CachedImage(url: url, contentMode: .fit, onImageSizeChange: onImageSizeChange) {
            ProgressView().tint(.white)
        }
        .frame(maxWidth: size.width, maxHeight: size.height)
        .scaleEffect(scale)
        .offset(offset)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: scale)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(dragGesture, including: scale > 1.01 ? .all : .none)
        .onChange(of: scale) { onScaleChange(scale) }
        .onDisappear { onScaleChange(1) }
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                settledScale = settledScale > 1 ? 1 : 2
                settledOffset = .zero
            }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                settledScale = min(4, max(1, settledScale * value))
                settledOffset = clampedOffset(settledOffset)
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragTranslation) { value, state, _ in
                guard scale > 1 else { return }
                state = value.translation
            }
            .onEnded { value in
                guard scale > 1 else { return }
                settledOffset = clampedOffset(CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height))
            }
    }

    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        let horizontalLimit = max(0, size.width * (scale - 1) / 2)
        let verticalLimit = max(0, size.height * (scale - 1) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, proposed.width)),
            height: min(verticalLimit, max(-verticalLimit, proposed.height)))
    }
}

struct StreamingVideoPlayer: View {
    let url: URL
    @State private var item: AVPlayerItem
    @State private var player: AVPlayer
    @State private var resumeAfterCancellation = false
    @State private var showsLoading = true
    @State private var failed = false

    init(url: URL) {
        self.url = url
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable"])
        // 服务端支持 Range；只预取短缓冲即可开始，不等待整段视频下载。
        item.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        _item = State(initialValue: item)
        _player = State(initialValue: player)
    }

    var body: some View {
        ZStack {
            Color.black
            VideoPlayer(player: player)
            if failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("视频加载失败")
                }
                .font(DS.Typo.secondary.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .allowsHitTesting(false)
            } else if showsLoading {
                ProgressView()
                    .tint(.white)
                    .allowsHitTesting(false)
            }
        }
            .onReceive(item.publisher(for: \.status)) { status in
                switch status {
                case .readyToPlay:
                    showsLoading = false
                case .failed:
                    showsLoading = false
                    failed = true
                default:
                    break
                }
            }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                if status == .playing {
                    showsLoading = false
                } else if status == .waitingToPlayAtSpecifiedRate, !failed {
                    showsLoading = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaViewerPauseVideo)) { _ in
                resumeAfterCancellation = player.timeControlStatus == .playing
                player.pause()
            }
            .onReceive(NotificationCenter.default.publisher(for: .mediaViewerResumeVideo)) { _ in
                if resumeAfterCancellation { player.play() }
                resumeAfterCancellation = false
            }
            .onDisappear { player.pause() }
    }
}

private typealias MediaViewerVideoPage = StreamingVideoPlayer

enum MediaSaver {
    static func saveImage(from url: URL) async -> Bool {
        let destination: URL
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: url)
            destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(imageExtension(for: response, fallbackURL: url))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: destination, options: nil)
            }
            return true
        } catch {
            return false
        }
    }

    private static func imageExtension(for response: URLResponse, fallbackURL: URL) -> String {
        switch response.mimeType?.lowercased() {
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/tiff": return "tiff"
        case "image/jpeg": return "jpg"
        default:
            return fallbackURL.pathExtension.isEmpty ? "jpg" : fallbackURL.pathExtension
        }
    }

    static func saveVideo(from url: URL) async -> Bool {
        do {
            let (source, _) = try await URLSession.shared.download(from: url)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "mp4" : url.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: source, to: destination)
            await MainActor.run {
                UISaveVideoAtPathToSavedPhotosAlbum(destination.path, nil, nil, nil)
            }
            return true
        } catch {
            return false
        }
    }
}
