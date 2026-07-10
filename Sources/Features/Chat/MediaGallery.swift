import SwiftUI
import AVKit
import AVFoundation
import PhotosUI

struct MediaGallerySheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFile: ChatMessage?
    @State private var selectedMediaId: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var mediaMessages: [ChatMessage] {
        store.mediaMessages(for: channel, includeFiles: true)
    }

    private var previewableMessages: [ChatMessage] {
        mediaMessages.filter { $0.type != "file" }
    }

    var body: some View {
        NavigationStack {
            if mediaMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                    Text("暂无媒体或文件")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("媒体与文件")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(mediaMessages) { msg in
                            mediaThumb(msg)
                        }
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
        }
        .fullScreenCover(isPresented: Binding(
            get: { selectedMediaId != nil },
            set: { if !$0 { selectedMediaId = nil } }
        )) {
            MediaPagerView(messages: previewableMessages, selectedId: $selectedMediaId)
                .presentationBackground(.clear)
        }
    }

    @ViewBuilder
    private func mediaThumb(_ msg: ChatMessage) -> some View {
        if msg.type == "file" {
            fileThumb(msg)
                .onTapGesture { selectedFile = msg }
        } else if msg.type == "video", let url = msg.mediaURL {
            ZStack {
                VideoThumbnailView(url: url)
                    .aspectRatio(contentMode: .fill)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: (UIScreen.main.bounds.width - 4) / 3)
            .clipped()
            .onTapGesture { selectedMediaId = MediaBrowserItem.items(for: msg).first?.id ?? msg.id }
        } else if let url = msg.mediaURL {
            CachedImage(url: url) {
                Color.gray.opacity(0.15)
                    .overlay(ProgressView().tint(DS.Palette.accent))
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: (UIScreen.main.bounds.width - 4) / 3)
            .clipped()
            .onTapGesture { selectedMediaId = MediaBrowserItem.items(for: msg).first?.id ?? msg.id }
        } else {
            fallbackThumb(msg)
                .onTapGesture { selectedMediaId = MediaBrowserItem.items(for: msg).first?.id ?? msg.id }
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
        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
    }

    private func fileThumb(_ msg: ChatMessage) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DS.Palette.accent)
            Text(fileTitle(msg))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
        .background(DS.Palette.innerSurface)
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
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(DS.Palette.textPrimary)
                                .multilineTextAlignment(.center)
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Label("打开文件", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(DS.Palette.accent, in: Capsule())
                            }
                            .buttonStyle(PressableStyle())
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if msg.type == "video" {
                        VideoPlayer(player: AVPlayer(url: url))
                    } else {
                        CachedImage(url: url, contentMode: .fit) {
                            ProgressView()
                        }
                    }
                }
                Spacer()

                HStack(spacing: 12) {
                    Text(msg.senderName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(Self.dateTime(msg.ts))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .padding(.bottom, 20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { selectedFile = nil }
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
