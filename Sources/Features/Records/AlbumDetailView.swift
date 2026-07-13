import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AlbumDetailView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AlbumDetailViewModel
    @State private var selectedAsset: MomentAsset?
    @State private var captionAsset: MomentAsset?
    @State private var showingSettings = false
    @State private var confirmingDelete = false
    @State private var showingMediaPicker = false
    @State private var uploadProgress: (completed: Int, total: Int)?

    init(album: MomentAlbum) {
        _model = StateObject(wrappedValue: AlbumDetailViewModel(album: album))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                albumHeader
                content
            }
            .padding(DS.Spacing.page)
        }
        .background(AppPageBackground())
        .navigationTitle(model.album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingMediaPicker = true
                } label: {
                    Image(systemName: "photo.badge.plus").frame(width: 40, height: 40)
                }
                .disabled(uploadProgress != nil)
                .accessibilityLabel("从手机上传照片或视频")
                Menu {
                    Button("编辑相册", systemImage: "pencil") { showingSettings = true }
                    Button("删除相册", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("相册管理")
            }
        }
        .task { await load() }
        .refreshable { await reloadUnavailableCache() }
        .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
            guard note.persistentSyncIncludes(["album", "album_item", "media_note", "media_asset"]) else {
                return
            }
            Task { await reloadUnavailableCache() }
        }
        .sheet(item: $captionAsset) { asset in
            CaptionEditorSheet(asset: asset) { caption in
                await updateCaption(asset, caption: caption)
            }
        }
        .sheet(isPresented: $showingSettings) {
            AlbumManagementSheet(album: model.album) { title, summary in
                await updateAlbum(title: title, summary: summary)
            }
        }
        .sheet(isPresented: $showingMediaPicker) {
            AlbumMediaPicker(isPresented: $showingMediaPicker) { items in
                upload(items)
            }
            .ignoresSafeArea()
        }
        .confirmationDialog(
            "删除“\(model.album.title)”？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除相册", role: .destructive) { Task { await deleteAlbum() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除相册整理关系，不会删除原聊天消息。")
        }
        .fullScreenCover(item: $selectedAsset) { asset in
            MomentAssetViewer(asset: asset) { captionAsset = asset }
        }
    }

    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.compact) {
            HStack {
                Text("\(model.album.itemCount) 个共同片段")
                    .font(DS.Typo.secondary.weight(.semibold))
                    .foregroundStyle(DS.Palette.purple)
                Spacer()
                if let progress = uploadProgress {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .frame(maxWidth: 120)
                        .accessibilityLabel("正在上传")
                        .accessibilityValue("\(progress.completed) / \(progress.total)")
                }
            }
            if let note = model.album.note, !note.isEmpty {
                Text(note)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.assets.isEmpty {
            ProgressView("正在打开相册…")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if model.assets.isEmpty {
            VStack(spacing: 14) {
                AppEmptyState(
                    "相册还是空的",
                    systemImage: "photo.badge.plus",
                    detail: "可以从手机直接上传，也可以在聊天里长按照片或视频收藏。")
                Button("从手机选择", systemImage: "photo.on.rectangle.angled") {
                    showingMediaPicker = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploadProgress != nil)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 142, maximum: 260), spacing: 4)],
                spacing: 4
            ) {
                ForEach(model.assets) { asset in
                    assetTile(asset)
                        .task { await loadMore(asset) }
                }
            }
            if model.loadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        if let message = model.errorMessage {
            StatusBanner(text: message, kind: .error)
        }
    }

    private func assetTile(_ asset: MomentAsset) -> some View {
        Button { selectedAsset = asset } label: {
            Group {
                if asset.isVideo {
                    ZStack {
                        LinearGradient(
                            colors: [DS.Palette.purple.opacity(0.28), DS.Palette.blue.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                } else {
                    CachedImage(url: asset.resolvedURL) {
                        ZStack {
                            DS.Palette.innerSurface
                            Image(systemName: "photo")
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let caption = asset.caption, !caption.isEmpty {
                    Text(caption)
                        .font(DS.Typo.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(
                            colors: [.clear, .black.opacity(0.64)],
                            startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(alignment: .topTrailing) {
                if asset.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.38), in: Circle())
                        .padding(7)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑注脚", systemImage: "pencil") { captionAsset = asset }
            Button("移出相册", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await remove(asset) }
            }
        }
        .accessibilityLabel(asset.caption?.isEmpty == false ? asset.caption! : (asset.isVideo ? "视频" : "照片"))
        .accessibilityHint("轻点查看，长按编辑注脚")
    }

    private func load() async {
        guard let token = store.session?.token else { return }
        await model.load(token: token)
    }

    private func loadMore(_ asset: MomentAsset) async {
        guard let token = store.session?.token else { return }
        await model.loadMoreIfNeeded(asset: asset, token: token)
    }

    private func updateCaption(_ asset: MomentAsset, caption: String?) async -> Bool {
        guard let token = store.session?.token else { return false }
        return await model.updateCaption(asset: asset, caption: caption, token: token)
    }

    private func updateAlbum(title: String, summary: String) async -> Bool {
        guard let token = store.session?.token else { return false }
        return await model.updateAlbum(title: title, summary: summary, token: token)
    }

    private func remove(_ asset: MomentAsset) async {
        guard let token = store.session?.token else { return }
        await model.remove(asset, token: token)
    }

    private func deleteAlbum() async {
        guard let token = store.session?.token else { return }
        if await model.deleteAlbum(token: token) { dismiss() }
    }

    private func reloadUnavailableCache() async {
        guard let token = store.session?.token else { return }
        await model.load(token: token, force: true)
    }

    private func upload(_ items: [AlbumPickedMedia]) {
        guard !items.isEmpty, let session = store.session else { return }
        uploadProgress = (0, items.count)
        Task {
            let uploader = MediaUploadService()
            for (index, item) in items.enumerated() {
                defer { item.removeTemporaryFile() }
                do {
                    let uploaded: MediaUploadResult
                    if let fileURL = item.fileURL {
                        uploaded = try await uploader.upload(
                            fileURL: fileURL, mimeType: item.mimeType, purpose: .album, session: session)
                    } else if let data = item.data {
                        uploaded = try await uploader.upload(
                            data: data, mimeType: item.mimeType, purpose: .album, session: session)
                    } else {
                        continue
                    }
                    await model.addUpload(
                        uploadId: uploaded.id,
                        takenAt: item.takenAt,
                        token: session.token)
                } catch {
                    await MainActor.run { model.errorMessage = error.localizedDescription }
                }
                await MainActor.run { uploadProgress = (index + 1, items.count) }
            }
            await MainActor.run { uploadProgress = nil }
        }
    }
}

private struct AlbumPickedMedia: Identifiable, @unchecked Sendable {
    let id = UUID()
    let data: Data?
    let fileURL: URL?
    let mimeType: String
    let takenAt: Int

    func removeTemporaryFile() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct AlbumMediaPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPicked: ([AlbumPickedMedia]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 20
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: AlbumMediaPicker

        init(parent: AlbumMediaPicker) { self.parent = parent }

        nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            Task { @MainActor in
                var loaded: [AlbumPickedMedia] = []
                for result in results {
                    if let media = await Self.load(result.itemProvider) { loaded.append(media) }
                }
                await MainActor.run {
                    self.parent.isPresented = false
                    self.parent.onPicked(loaded)
                }
            }
        }

        private static func load(_ provider: NSItemProvider) async -> AlbumPickedMedia? {
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
               let file = await copiedFile(from: provider, typeIdentifier: UTType.movie.identifier) {
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "video/quicktime"
                return AlbumPickedMedia(
                    data: nil, fileURL: file, mimeType: mime,
                    takenAt: Int(Date().timeIntervalSince1970 * 1_000))
            }
            let identifiers = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.image.identifier]
            for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
                if let data = await data(from: provider, typeIdentifier: identifier) {
                    let mime = UTType(identifier)?.preferredMIMEType ?? "image/jpeg"
                    return AlbumPickedMedia(
                        data: data, fileURL: nil, mimeType: mime,
                        takenAt: Int(Date().timeIntervalSince1970 * 1_000))
                }
            }
            return nil
        }

        private static func data(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        private static func copiedFile(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
            await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

private struct CaptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let asset: MomentAsset
    let onSave: (String?) async -> Bool
    @State private var caption: String
    @State private var saving = false

    init(asset: MomentAsset, onSave: @escaping (String?) async -> Bool) {
        self.asset = asset
        self.onSave = onSave
        _caption = State(initialValue: asset.caption ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("这张照片背后的故事", text: $caption, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle("共同注脚")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        Task {
                            saving = true
                            let value = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await onSave(value.isEmpty ? nil : value) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }
}

private struct MomentAssetViewer: View {
    @Environment(\.dismiss) private var dismiss
    let asset: MomentAsset
    let editCaption: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                MomentMediaContent(asset: asset)
                    .accessibilityLabel(asset.caption ?? (asset.isVideo ? "视频预览" : "照片预览"))
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.tint(.white)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("注脚", systemImage: "pencil") {
                        dismiss()
                        editCaption()
                    }
                    .tint(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let caption = asset.caption, !caption.isEmpty {
                    Text(caption)
                        .font(DS.Typo.body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.black.opacity(0.72))
                }
            }
        }
    }
}

private struct MomentMediaContent: View {
    let asset: MomentAsset
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if asset.isVideo, let player {
                VideoPlayer(player: player)
            } else {
                CachedImage(url: ServerConfig.resolveMediaURL(asset.url)) {
                    ProgressView().tint(.white)
                }
                .scaledToFit()
            }
        }
        .task(id: asset.id) {
            guard asset.isVideo,
                  let url = ServerConfig.resolveMediaURL(asset.url) else { return }
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
