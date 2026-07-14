import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct AlbumDetailView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AlbumDetailViewModel
    @State private var selectedMediaID: String?
    @State private var previewItems: [MediaBrowserItem] = []
    @State private var captionPost: AlbumTimelinePost?
    @State private var deletingPost: AlbumTimelinePost?
    @State private var mediaSourceRegistry = AlbumMediaSourceRegistry()
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
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            AppPageBackground()

            GeometryReader { proxy in
                let pageWidth = min(
                    760,
                    max(0, proxy.size.width - DS.Spacing.page * 2))

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.section) {
                        albumHeader
                        content(width: pageWidth)
                    }
                    .frame(width: pageWidth, alignment: .leading)
                    .padding(.vertical, DS.Spacing.gap)
                    .frame(maxWidth: .infinity)
                }
                .scrollClipDisabled(false)
            }
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .persistentSyncChanged)) { note in
            guard note.persistentSyncIncludes(["album", "album_item", "media_note", "media_asset"]) else {
                return
            }
            Task { await reloadUnavailableCache() }
        }
        .sheet(item: $captionPost) { post in
            PostCaptionEditorSheet(caption: post.caption) { caption in
                await updateCaption(post, caption: caption)
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
        .confirmationDialog(
            "删除这条共同动态？",
            isPresented: Binding(
                get: { deletingPost != nil },
                set: { if !$0 { deletingPost = nil } }),
            titleVisibility: .visible
        ) {
            Button("从相册中删除", role: .destructive) {
                guard let post = deletingPost else { return }
                deletingPost = nil
                Task { await remove(post) }
            }
            Button("取消", role: .cancel) { deletingPost = nil }
        } message: {
            Text("会移除这一条动态中的照片和视频，不会删除聊天原件。")
        }
        .background(MediaViewerPresenter(
            items: previewItems,
            selectedId: $selectedMediaID,
            sourceProvider: { mediaSourceRegistry.view(for: $0) }))
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
            }
            if let progress = uploadProgress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress.completed == 0 ? "正在准备上传" : "正在上传到共同相册")
                            .font(DS.Typo.secondary.weight(.semibold))
                            .foregroundStyle(DS.Palette.textPrimary)
                        Spacer()
                        Text("\(progress.completed) / \(progress.total)")
                            .font(DS.Typo.caption.monospacedDigit())
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    ProgressView(
                        value: Double(progress.completed),
                        total: Double(max(1, progress.total)))
                        .tint(DS.Palette.accent)
                    Text("上传完成后会自动出现在时间线中")
                        .font(DS.Typo.micro)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .padding(12)
                .background(DS.Palette.accent.opacity(0.08), in: RoundedRectangle(
                    cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在上传共同相册")
                .accessibilityValue("已完成 \(progress.completed)，共 \(progress.total) 项")
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
    private func content(width: CGFloat) -> some View {
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
                    timelinePost(post, width: width)
                    if post.id != timelinePosts.last?.id {
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
            if model.loadingMore {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        if let message = model.errorMessage {
            StatusBanner(text: message, kind: .error)
        }
    }

    private func timelinePost(_ post: AlbumTimelinePost, width: CGFloat) -> some View {
        let railWidth: CGFloat = 54
        let spacing: CGFloat = 12
        let bodyWidth = max(0, width - railWidth - spacing)

        return HStack(alignment: .top, spacing: spacing) {
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
            .frame(width: railWidth)

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
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if post.caption.isEmpty {
                        Text("还没有写下这一刻")
                            .font(DS.Typo.secondary)
                            .foregroundStyle(DS.Palette.textTertiary)
                    } else {
                        Text(post.caption)
                            .font(DS.Typo.body)
                            .foregroundStyle(DS.Palette.textPrimary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { captionPost = post } label: {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.accent)
                    .accessibilityLabel(post.caption.isEmpty ? "添加文案" : "编辑文案")
                    Menu {
                        Button("编辑文案", systemImage: "pencil") { captionPost = post }
                        Button("删除动态", systemImage: "trash", role: .destructive) { deletingPost = post }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityLabel("动态操作")
                }
                .contentShape(Rectangle())
                .zIndex(2)
                postMediaGrid(post.assets, width: bodyWidth)
                    .zIndex(0)
            }
            .padding(.vertical, 16)
            .frame(width: bodyWidth, alignment: .leading)
            .task { if let last = post.assets.last { await loadMore(last) } }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    private func postMediaGrid(_ assets: [MomentAsset], width: CGFloat) -> some View {
        let count = min(3, max(1, assets.count))
        let gap: CGFloat = 4
        let tileWidth = max(1, (width - gap * CGFloat(count - 1)) / CGFloat(count))
        let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: gap), count: count)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(assets) { asset in assetTile(asset, postAssets: assets, side: tileWidth) }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }

    private func assetTile(_ asset: MomentAsset, postAssets: [MomentAsset], side: CGFloat) -> some View {
        Button {
            openPreview(asset, in: postAssets)
        } label: {
            ZStack {
                if asset.isVideo, let url = asset.resolvedOriginalURL {
                    VideoThumbnailView(url: url)
                        .allowsHitTesting(false)
                } else {
                    CachedImage(url: asset.resolvedURL) {
                        ZStack {
                            DS.Palette.innerSurface
                            Image(systemName: "photo")
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
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
        .background {
            AlbumMediaSourceAnchor(id: asset.id, registry: mediaSourceRegistry)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("移出相册", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await remove(asset) }
            }
        }
        .accessibilityLabel(asset.caption?.isEmpty == false ? asset.caption! : (asset.isVideo ? "视频" : "照片"))
        .accessibilityHint("轻点全屏查看，左右滑动查看这条动态中的媒体")
    }

    private func openPreview(_ asset: MomentAsset, in postAssets: [MomentAsset]) {
        // 展示器必须先收到完整媒体数组，再设置选中项；同一轮状态更新会偶发
        // 让 UIKit Presenter 拿到空数组，从而表现为“点了没有反应”。
        previewItems = postAssets.map(\.mediaBrowserItem)
        DispatchQueue.main.async {
            selectedMediaID = asset.id
        }
    }

    private func load() async {
        guard let token = store.session?.token else { return }
        await model.load(token: token)
    }

    private func loadMore(_ asset: MomentAsset) async {
        guard let token = store.session?.token else { return }
        await model.loadMoreIfNeeded(asset: asset, token: token)
    }

    private func updateCaption(_ post: AlbumTimelinePost, caption: String?) async -> Bool {
        guard let token = store.session?.token else { return false }
        return await model.updateCaption(assets: post.assets, caption: caption, token: token)
    }

    private func updateAlbum(title: String, summary: String) async -> Bool {
        guard let token = store.session?.token else { return false }
        return await model.updateAlbum(title: title, summary: summary, token: token)
    }

    private func remove(_ asset: MomentAsset) async {
        guard let token = store.session?.token else { return }
        await model.remove(asset, token: token)
    }

    private func remove(_ post: AlbumTimelinePost) async {
        guard let token = store.session?.token else { return }
        await model.remove(assets: post.assets, token: token)
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
        let postId = "post_\(UUID().uuidString.lowercased())"
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
                        postId: postId,
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
            if let postId = asset.postId, !postId.isEmpty { return postId }
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

private struct PostCaptionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String?) async -> Bool
    @State private var caption: String
    @State private var saving = false

    init(caption: String, onSave: @escaping (String?) async -> Bool) {
        self.onSave = onSave
        _caption = State(initialValue: caption)
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

@MainActor
private final class AlbumMediaSourceRegistry {
    private let views = NSMapTable<NSString, UIView>(
        keyOptions: .strongMemory,
        valueOptions: .weakMemory)

    func register(_ view: UIView, id: String) {
        views.setObject(view, forKey: id as NSString)
    }

    func remove(id: String, view: UIView) {
        guard views.object(forKey: id as NSString) === view else { return }
        views.removeObject(forKey: id as NSString)
    }

    func view(for id: String) -> UIView? {
        views.object(forKey: id as NSString)
    }
}

private struct AlbumMediaSourceAnchor: UIViewRepresentable {
    let id: String
    let registry: AlbumMediaSourceRegistry

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        registry.register(view, id: id)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        registry.register(uiView, id: id)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Void) {
        // Registry uses weak values; recycled timeline cells disappear automatically.
    }
}
