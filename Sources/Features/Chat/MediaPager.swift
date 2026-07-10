import SwiftUI
import AVKit
import AVFoundation
import UIKit
import Photos

/// 沉浸式媒体浏览：不显示页码或工具栏，操作只在手势和长按菜单中出现。
struct MediaPagerView: View {
    let items: [MediaBrowserItem]
    @Binding var selectedId: String?

    @EnvironmentObject private var favorites: MediaFavoriteStore
    @GestureState private var dismissTranslation: CGSize = .zero
    @State private var saving = false
    @State private var toast: String?
    @State private var closingProgress: CGFloat = 0
    @State private var closingOffset: CGFloat = 0
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(messages: [ChatMessage], selectedId: Binding<String?>) {
        self.items = messages.flatMap(MediaBrowserItem.items(for:))
        _selectedId = selectedId
    }

    init(items: [MediaBrowserItem], selectedId: Binding<String?>) {
        self.items = items
        _selectedId = selectedId
    }

    private var dismissProgress: CGFloat {
        max(closingProgress, min(1, max(0, dismissTranslation.height / 260)))
    }

    private var dismissOffset: CGFloat {
        closingProgress > 0 ? closingOffset : max(0, dismissTranslation.height)
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
            Color.black
                .opacity(appeared ? Double(CGFloat(1) - dismissProgress) : 0)
                .ignoresSafeArea()

            if items.isEmpty {
                Text("暂无媒体")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                // 保持稳定的完整页序列；之前在手势中动态增删相邻页，会让 PageViewController
                // 丢失当前索引，从而卡在两张图之间。图片加载由缓存和预取负责。
                TabView(selection: selection) {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        MediaPage(
                            item: item,
                            shouldLoadMedia: abs(index - selectedIndex) <= 1,
                            isFavorite: favorites.contains(item),
                            onSave: { save(item) },
                            onToggleFavorite: { toggleFavorite(item) }
                        )
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .offset(y: dismissOffset)
                .scaleEffect(CGFloat(1) - dismissProgress * 0.12)
                .scaleEffect(appeared ? 1 : (reduceMotion ? 1 : 0.92))
                .opacity(appeared ? Double(CGFloat(1) - dismissProgress * 0.76) : 0)
                .simultaneousGesture(dismissGesture)
                .task(id: selectedId) {
                    prefetchAroundSelection()
                }
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 42)
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            closingProgress = 0
            closingOffset = 0
            withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.34, dampingFraction: 0.88)) {
                appeared = true
            }
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dismissTranslation) { value, state, transaction in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                transaction.animation = .interactiveSpring(response: 0.22, dampingFraction: 0.88)
                state = value.translation
            }
            .onEnded { value in
                guard (value.translation.height > 90 || value.predictedEndTranslation.height > 190),
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dismiss(with: value.translation.height)
            }
    }

    private func dismiss(with translation: CGFloat) {
        closingOffset = max(translation, 150)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            closingProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            selectedId = nil
        }
    }

    private func prefetchAroundSelection() {
        guard !items.isEmpty else { return }
        guard let currentIndex = items.firstIndex(where: { $0.id == selectedId }) else { return }
        let lower = max(items.startIndex, currentIndex - 2)
        let upper = min(items.index(before: items.endIndex), currentIndex + 2)
        for index in lower...upper {
            guard !items[index].isVideo, let url = items[index].mediaURL else { continue }
            Task.detached(priority: .userInitiated) {
                _ = await ImageCache.shared.image(for: url)
            }
        }
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if item.isVideo, let url = item.mediaURL, shouldLoadMedia {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let url = item.mediaURL, shouldLoadMedia {
                    ZoomableRemoteImage(url: url, size: geometry.size)
                } else if item.mediaURL != nil {
                    ProgressView().tint(.white.opacity(0.7))
                } else {
                    failedView
                }

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            // 不提供原图片的上下文预览，避免系统先把大图抬起并遮住菜单。
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
            }, preview: {
                Color.clear.frame(width: 1, height: 1)
            })
        }
        .ignoresSafeArea()
    }

    private var failedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
            Text("加载失败")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.72))
    }
}

private struct ZoomableRemoteImage: View {
    let url: URL
    let size: CGSize

    @State private var settledScale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    private var scale: CGFloat {
        min(4, max(1, settledScale * magnification))
    }

    var body: some View {
        CachedImage(url: url, contentMode: .fit) {
            ProgressView().tint(.white)
        }
        .frame(maxWidth: size.width, maxHeight: size.height)
        .scaleEffect(scale)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: scale)
        .gesture(magnifyGesture)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                settledScale = settledScale > 1 ? 1 : 2
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
            }
    }
}

enum MediaSaver {
    static func saveImage(from url: URL) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return false }
            await MainActor.run {
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
            return true
        } catch {
            return false
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
