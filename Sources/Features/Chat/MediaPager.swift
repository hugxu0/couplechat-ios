import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// 沉浸式媒体浏览：不显示页码或工具栏，操作只在手势和长按菜单中出现。
struct MediaPagerView: View {
    let items: [MediaBrowserItem]
    @Binding var selectedId: String?

    @EnvironmentObject private var favorites: MediaFavoriteStore
    @GestureState private var dismissTranslation: CGSize = .zero
    @State private var saving = false
    @State private var toast: String?

    init(messages: [ChatMessage], selectedId: Binding<String?>) {
        self.items = messages.compactMap(MediaBrowserItem.init(message:))
        _selectedId = selectedId
    }

    init(items: [MediaBrowserItem], selectedId: Binding<String?>) {
        self.items = items
        _selectedId = selectedId
    }

    private var selection: Binding<String> {
        Binding(
            get: { selectedId ?? items.first?.id ?? "" },
            set: { selectedId = $0 }
        )
    }

    private var dismissProgress: CGFloat {
        min(1, max(0, dismissTranslation.height / 260))
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissProgress * 0.72)
                .ignoresSafeArea()

            if items.isEmpty {
                Text("暂无媒体")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                TabView(selection: selection) {
                    ForEach(items) { item in
                        MediaPage(
                            item: item,
                            isFavorite: favorites.contains(item),
                            onSave: { save(item) },
                            onToggleFavorite: { toggleFavorite(item) }
                        )
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .offset(y: max(0, dismissTranslation.height))
                .scaleEffect(1 - dismissProgress * 0.08)
                .simultaneousGesture(dismissGesture)
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
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dismissTranslation) { value, state, _ in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                state = value.translation
            }
            .onEnded { value in
                guard value.translation.height > 110,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                selectedId = nil
            }
    }

    private func save(_ item: MediaBrowserItem) {
        guard let url = item.mediaURL, !saving else { return }
        saving = true
        Task {
            let success = item.isVideo
                ? await MediaSaver.saveVideo(from: url)
                : await MediaSaver.saveImage(from: url)
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
    let isFavorite: Bool
    let onSave: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if item.isVideo, let url = item.mediaURL {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let url = item.mediaURL {
                    ZoomableRemoteImage(url: url, size: geometry.size)
                } else {
                    failedView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .contextMenu {
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
            }
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
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView().tint(.white)
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: size.width, maxHeight: size.height)
                    .scaleEffect(scale)
                    .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.86), value: scale)
                    .gesture(magnifyGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            settledScale = settledScale > 1 ? 1 : 2
                        }
                    }
            case .failure:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.72))
            @unknown default:
                EmptyView()
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
