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
    @State private var showingPostComposer = false
    @State private var draftMedia: [AlbumPickedMedia] = []
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
            .frame(maxWidth: 760)
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, DS.Spacing.gap)
            .frame(maxWidth: .infinity)
        }
        .background(AppPageBackground())
        .navigationTitle(model.album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingMediaPicker = true
                } label: {
                    Image(systemName: "square.and.pencil").frame(width: 40, height: 40)
                }
                .disabled(uploadProgress != nil)
                .accessibilityLabel("发表共同动态")
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
                guard !items.isEmpty else { return }
                draftMedia = items
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showingPostComposer = true
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingPostComposer, onDismiss: discardDraftMedia) {
            AlbumPostComposerSheet(mediaCount: draftMedia.count) { caption in
                let items = draftMedia
                draftMedia = []
                showingPostComposer = false
                upload(items, caption: caption)
            }
            .presentationDetents([.medium])
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("我们的动态")
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text("\(timelinePosts.count) 条记录 · \(model.album.itemCount) 个片段")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
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
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(radius: DS.Radius.card)
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
                    "还没有共同动态",
                    systemImage: "photo.badge.plus",
                    detail: "选几张照片或一段视频，写下当时想说的话。")
                Button("发表第一条", systemImage: "square.and.pencil") {
                    showingMediaPicker = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploadProgress != nil)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(timelinePosts) { post in
                    timelinePost(post)
                    if post.id != timelinePosts.last?.id {
                        Divider().padding(.leading, 70)
                    }
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

    private func timelinePost(_ post: AlbumTimelinePost) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text(post.day)
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(post.month)
                    .font(DS.Typo.micro.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                Circle()
                    .fill(DS.Palette.orange)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 3))
                    .padding(.top, 5)
                Rectangle()
                    .fill(DS.Palette.orange.opacity(0.16))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 54)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sharedAuthorName)
                        .font(DS.Typo.secondary.weight(.semibold))
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    Text(post.time)
                        .font(DS.Typo.micro.monospacedDigit())
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                if !post.caption.isEmpty {
                    Text(post.caption)
                        .font(DS.Typo.body)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                postMediaGrid(post.assets)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { if let last = post.assets.last { await loadMore(last) } }
        }
    }

    private func postMediaGrid(_ assets: [MomentAsset]) -> some View {
        let count = min(3, max(1, assets.count))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(assets) { asset in assetTile(asset) }
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            Button("编辑文案", systemImage: "pencil") { captionAsset = asset }
            Button("移出相册", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await remove(asset) }
            }
        }
        .accessibilityLabel(asset.caption?.isEmpty == false ? asset.caption! : (asset.isVideo ? "视频" : "照片"))
        .accessibilityHint("轻点查看，长按编辑文案")
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

    private func upload(_ items: [AlbumPickedMedia], caption: String) {
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
                    let added = await model.addUpload(
                        uploadId: uploaded.id,
                        takenAt: item.takenAt,
                        token: session.token)
                    if !caption.isEmpty {
                        for asset in added {
                            _ = await model.updateCaption(
                                asset: asset, caption: caption, token: session.token)
                        }
                    }
                } catch {
                    await MainActor.run { model.errorMessage = error.localizedDescription }
                }
                await MainActor.run { uploadProgress = (index + 1, items.count) }
            }
            await MainActor.run { uploadProgress = nil }
        }
    }

    private var timelinePosts: [AlbumTimelinePost] {
        AlbumTimelinePost.group(model.assets)
    }

    private var sharedAuthorName: String {
        let mine = store.session?.name ?? "我"
        let partner = store.partner?.name ?? "TA"
        return "\(mine)和\(partner)"
    }

    private func discardDraftMedia() {
        guard !showingPostComposer else { return }
        draftMedia.forEach { $0.removeTemporaryFile() }
        draftMedia = []
    }
}

private struct AlbumTimelinePost: Identifiable {
    let id: String
    let timestamp: Int
    let caption: String
    let assets: [MomentAsset]

    var day: String { Self.dayFormatter.string(from: date) }
    var month: String { Self.monthFormatter.string(from: date) }
    var time: String { Self.timeFormatter.string(from: date) }

    private var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1_000) }

    static func group(_ assets: [MomentAsset]) -> [AlbumTimelinePost] {
        let grouped = Dictionary(grouping: assets) { asset in
            let minute = asset.takenAt / 60_000
            let caption = asset.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(minute)|\(caption)"
        }
        return grouped.map { key, values in
            let ordered = values.sorted { $0.takenAt > $1.takenAt }
            return AlbumTimelinePost(
                id: key,
                timestamp: ordered.map(\.takenAt).max() ?? 0,
                caption: ordered.first?.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                assets: ordered)
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

private struct AlbumPostComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mediaCount: Int
    let onPublish: (String) -> Void
    @State private var caption = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.stack.fill")
                        .font(.title2)
                        .foregroundStyle(DS.Palette.orange)
                        .frame(width: 48, height: 48)
                        .background(DS.Palette.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已选择 \(mediaCount) 个片段")
                            .font(DS.Typo.secondary.weight(.semibold))
                        Text("将以一条共同动态发表")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }

                TextField("写下这一刻…", text: $caption, axis: .vertical)
                    .font(DS.Typo.body)
                    .lineLimit(4...8)
                    .padding(14)
                    .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.page)
            .background(AppPageBackground())
            .navigationTitle("发表动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") {
                        onPublish(caption.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .fontWeight(.semibold)
                }
            }
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
                let batchTimestamp = Int(Date().timeIntervalSince1970 * 1_000)
                for result in results {
                    if let media = await Self.load(result.itemProvider, takenAt: batchTimestamp) {
                        loaded.append(media)
                    }
                }
                await MainActor.run {
                    self.parent.isPresented = false
                    self.parent.onPicked(loaded)
                }
            }
        }

        private static func load(_ provider: NSItemProvider, takenAt: Int) async -> AlbumPickedMedia? {
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
               let file = await copiedFile(from: provider, typeIdentifier: UTType.movie.identifier) {
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "video/quicktime"
                return AlbumPickedMedia(
                    data: nil, fileURL: file, mimeType: mime,
                    takenAt: takenAt)
            }
            let identifiers = [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.image.identifier]
            for identifier in identifiers where provider.hasItemConformingToTypeIdentifier(identifier) {
                if let data = await data(from: provider, typeIdentifier: identifier) {
                    let mime = UTType(identifier)?.preferredMIMEType ?? "image/jpeg"
                    return AlbumPickedMedia(
                        data: data, fileURL: nil, mimeType: mime,
                        takenAt: takenAt)
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
                TextField("写下这一刻", text: $caption, axis: .vertical)
                    .lineLimit(3...8)
            }
            .navigationTitle("编辑文案")
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
                    Button("文案", systemImage: "pencil") {
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
