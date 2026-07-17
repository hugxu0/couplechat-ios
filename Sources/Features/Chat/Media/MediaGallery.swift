import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import QuickLook

enum MediaCollectionGrid {
    static let spacing: CGFloat = 2
    static let columns = [GridItem(.adaptive(minimum: 100), spacing: spacing)]
}

private enum MediaGalleryCategory: String, CaseIterable, Identifiable {
    case media = "图片与视频"
    case files = "文件"

    var id: String { rawValue }
}

struct MediaGallerySheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFile: ChatMessage?
    @State private var selectedMediaId: String?
    @State private var mediaSourceRegistry = MediaViewerSourceRegistry()
    @State private var mediaMessages: [ChatMessage] = []
    @State private var category = MediaGalleryCategory.media
    @State private var filePreviewURL: URL?
    @State private var filePreviewTask: Task<Void, Never>?
    @State private var preparingFileID: String?
    @State private var fileError: String?

    private var previewableMessages: [ChatMessage] {
        mediaMessages.filter { $0.type != "file" }
    }

    private var fileMessages: [ChatMessage] {
        mediaMessages.filter { $0.type == "file" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("附件类型", selection: $category) {
                    ForEach(MediaGalleryCategory.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if category == .media {
                    if previewableMessages.isEmpty {
                        emptyState(title: "暂无图片或视频", icon: "photo.on.rectangle")
                    } else {
                        ScrollView {
                            LazyVGrid(
                                columns: MediaCollectionGrid.columns,
                                spacing: MediaCollectionGrid.spacing
                            ) {
                                ForEach(previewableMessages) { msg in
                                    mediaThumb(msg)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                } else if fileMessages.isEmpty {
                    emptyState(title: "暂无文件", icon: "doc")
                } else {
                    List(fileMessages) { msg in
                        Button {
                            selectedFile = msg
                        } label: {
                            fileRow(msg)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("媒体与文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $selectedFile) { msg in
                mediaDetail(msg)
            }
        }
        .background(MediaViewerPresenter(
            items: previewableMessages.flatMap(MediaBrowserItem.items(for:)),
            selectedId: $selectedMediaId,
            sourceProvider: { mediaSourceRegistry.view(for: $0) }))
        .task {
            mediaMessages = await store.mediaMessages(for: channel, includeFiles: true)
        }
    }

    private func emptyState(title: String, icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mediaThumb(_ msg: ChatMessage) -> some View {
        let identifier = MediaBrowserItem.items(for: msg).first?.id ?? msg.id
        return Button {
            selectedMediaId = identifier
        } label: {
            mediaThumbContent(msg)
        }
        .buttonStyle(.plain)
        .overlay {
            MediaViewerSourceAnchor(id: identifier, registry: mediaSourceRegistry)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(msg.type == "video" ? "查看视频" : "查看图片")
    }

    @ViewBuilder
    private func mediaThumbContent(_ msg: ChatMessage) -> some View {
        if msg.type == "video", let url = msg.mediaURL {
            ZStack {
                VideoThumbnailView(url: url)
                    .aspectRatio(contentMode: .fill)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
        } else if let url = msg.mediaURL {
            CachedImage(url: url) {
                Color.gray.opacity(0.15)
                    .overlay(ProgressView().tint(DS.Palette.accent))
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipped()
        } else {
            fallbackThumb(msg)
        }
    }

    @ViewBuilder
    private func fallbackThumb(_ msg: ChatMessage) -> some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: msg.type == "video" ? "play.rectangle" : "photo")
                .font(.system(size: 24))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }

    private func fileRow(_ msg: ChatMessage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.Palette.accent)
                .frame(width: 42, height: 42)
                .background(DS.Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(fileTitle(msg))
                    .font(.body.weight(.medium))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                Text("\(msg.senderName) · \(Self.dateTime(msg.ts))")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func mediaDetail(_ msg: ChatMessage) -> some View {
        NavigationStack {
            VStack {
                if let url = msg.mediaURL {
                    if msg.type == "file" {
                        VStack(spacing: 14) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 54, weight: .semibold))
                                .foregroundStyle(DS.Palette.accent)
                            Text(fileTitle(msg))
                                .font(DS.Typo.body.weight(.semibold))
                                .foregroundStyle(DS.Palette.textPrimary)
                                .multilineTextAlignment(.center)
                            Button {
                                prepareFile(msg, remoteURL: url)
                            } label: {
                                if preparingFileID == msg.id {
                                    HStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text("正在下载…")
                                    }
                                } else {
                                    Label("在应用内预览", systemImage: "doc.text.magnifyingglass")
                                }
                            }
                            .font(DS.Typo.button)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(DS.Palette.accent, in: Capsule())
                            .buttonStyle(PressableStyle())
                            .disabled(preparingFileID != nil)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if msg.type == "video" {
                        StreamingVideoPlayer(url: url)
                    } else {
                        CachedImage(url: url, contentMode: .fit) {
                            ProgressView()
                        }
                    }
                }
                Spacer()

                HStack(spacing: 12) {
                    Text(msg.senderName)
                        .font(DS.Typo.secondary.weight(.semibold))
                    Text(Self.dateTime(msg.ts))
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .padding(.bottom, 20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { selectedFile = nil }
                }
            }
            .quickLookPreview($filePreviewURL)
            .alert("文件打开失败", isPresented: Binding(
                get: { fileError != nil },
                set: { if !$0 { fileError = nil } }
            )) {
                Button("知道了", role: .cancel) { fileError = nil }
            } message: {
                Text(fileError ?? "请检查网络后重试。")
            }
            .onDisappear {
                filePreviewTask?.cancel()
                filePreviewTask = nil
                preparingFileID = nil
            }
        }
    }

    private func prepareFile(_ message: ChatMessage, remoteURL: URL) {
        guard preparingFileID == nil else { return }
        preparingFileID = message.id
        fileError = nil
        filePreviewTask = Task {
            do {
                let localURL = try await FilePreviewCache.localURL(
                    for: remoteURL,
                    messageID: message.id,
                    displayName: fileTitle(message))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    preparingFileID = nil
                    filePreviewURL = localURL
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    preparingFileID = nil
                    fileError = "请检查网络后重试。"
                }
            }
        }
    }

    private static func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }

    private func fileTitle(_ msg: ChatMessage) -> String {
        let text = msg.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != "[文件]" { return text }
        if let name = msg.mediaURL?.lastPathComponent, !name.isEmpty { return name }
        return "文件"
    }
}
