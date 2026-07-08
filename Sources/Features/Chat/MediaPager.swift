import SwiftUI
import AVKit
import AVFoundation
import PhotosUI

struct MediaPagerView: View {
    let messages: [ChatMessage]
    @Binding var selectedId: String?

    @State private var saving = false
    @State private var toast: String?

    private var selection: Binding<String> {
        Binding(
            get: { selectedId ?? messages.first?.id ?? "" },
            set: { selectedId = $0 }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if messages.isEmpty {
                Text("暂无媒体")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                TabView(selection: selection) {
                    ForEach(messages) { message in
                        MediaPage(message: message)
                            .tag(message.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            VStack {
                HStack(spacing: 12) {
                    Button {
                        selectedId = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.42), in: Circle())
                    }

                    Spacer()

                    Text(positionText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.38), in: Capsule())

                    Spacer()

                    Button {
                        saveCurrent()
                    } label: {
                        Group {
                            if saving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.42), in: Circle())
                    }
                    .disabled(saving || currentURL == nil)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()
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
    }

    private var currentMessage: ChatMessage? {
        guard let selectedId else { return messages.first }
        return messages.first { $0.id == selectedId } ?? messages.first
    }

    private var currentURL: URL? { currentMessage?.mediaURL }

    private var positionText: String {
        guard let currentMessage, let index = messages.firstIndex(where: { $0.id == currentMessage.id }) else {
            return "0/0"
        }
        return "\(index + 1)/\(messages.count)"
    }

    private func saveCurrent() {
        guard let currentMessage, let url = currentURL else { return }
        saving = true
        Task {
            let success: Bool
            if currentMessage.type == "video" {
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

    private func showToast(_ text: String) {
        withAnimation(DS.Anim.ease) {
            toast = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard toast == text else { return }
            withAnimation(DS.Anim.ease) {
                toast = nil
            }
        }
    }
}

struct MediaPage: View {
    let message: ChatMessage

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if message.type == "video", let url = mediaURL {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let url = mediaURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .tint(.white)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        case .failure:
                            failedView
                        @unknown default:
                            failedView
                        }
                    }
                } else {
                    failedView
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
    }

    private var mediaURL: URL? { message.mediaURL }

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

