import SwiftUI
import AVKit

struct MediaGallerySheet: View {
    let channel: ChatChannel

    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMedia: ChatMessage?
    @State private var fullScreenImage: UIImage?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    private var mediaMessages: [ChatMessage] {
        store.mediaMessages(for: channel, includeFiles: true)
    }

    var body: some View {
        NavigationStack {
            if mediaMessages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.Palette.textSecondary.opacity(0.4))
                    Text("鏆傛棤濯掍綋鎴栨枃浠?)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("濯掍綋涓庢枃浠?)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("鍏抽棴") { dismiss() }
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
                .navigationTitle("濯掍綋涓庢枃浠?)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("鍏抽棴") { dismiss() }
                    }
                }
                .sheet(item: $selectedMedia) { msg in
                    mediaDetail(msg)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaThumb(_ msg: ChatMessage) -> some View {
        if msg.type == "file" {
            fileThumb(msg)
                .onTapGesture { selectedMedia = msg }
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
            .onTapGesture { selectedMedia = msg }
        } else if let url = msg.mediaURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
                        .clipped()
                case .failure:
                    fallbackThumb(msg)
                case .empty:
                    Color.gray.opacity(0.15)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: (UIScreen.main.bounds.width - 4) / 3)
                        .overlay(ProgressView().tint(DS.Palette.accent))
                @unknown default:
                    fallbackThumb(msg)
                }
            }
            .onTapGesture { selectedMedia = msg }
        } else {
            fallbackThumb(msg)
                .onTapGesture { selectedMedia = msg }
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
                                Label("鎵撳紑鏂囦欢", systemImage: "arrow.up.right.square")
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
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                            case .failure:
                                VStack(spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.system(size: 40))
                                    Text("鍔犺浇澶辫触")
                                }
                                .foregroundStyle(DS.Palette.textSecondary)
                            case .empty:
                                ProgressView()
                            @unknown default:
                                EmptyView()
                            }
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
                    Button("鍏抽棴") { selectedMedia = nil }
                }
            }
        }
    }

    private static func dateTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M鏈坉鏃?HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts / 1000))
    }

    private func fileTitle(_ msg: ChatMessage) -> String {
        let text = msg.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty && text != "[鏂囦欢]" { return text }
        if let name = msg.mediaURL?.lastPathComponent, !name.isEmpty { return name }
        return "鏂囦欢"
    }
}
