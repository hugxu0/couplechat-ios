import SwiftUI
import PhotosUI
import AVFoundation

/// 输入栏组件：包含输入框、附件按钮、表情按钮、发送/语音按钮
struct ComposerView: View {
    let channel: ChatChannel
    @Bindable var viewModel: ChatViewModel
    @EnvironmentObject private var store: ChatStore
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if viewModel.isRecording {
                RecordingBar(viewModel: viewModel)
            } else {
                if channel == .couple {
                    CatButton()
                }
                MessageBox(
                    channel: channel,
                    viewModel: viewModel
                )
            }
            RightButton(viewModel: viewModel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - 小猫按钮

private struct CatButton: View {
    @EnvironmentObject private var store: ChatStore
    
    var body: some View {
        Button {
            // summonDaju() - TODO: 实现召唤大橘
        } label: {
            CatHeadIcon()
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 23, height: 23)
                .frame(width: ChatViewModel.composerButtonSize, height: ChatViewModel.composerButtonSize)
                .dsGlassInteractive(in: Circle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 输入框

private struct MessageBox: View {
    let channel: ChatChannel
    @Bindable var viewModel: ChatViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // 图片预览（如果有）
            if !viewModel.mediaPreviewItems.isEmpty {
                MediaPreviewRow(viewModel: viewModel)
            }
            
            // 输入行
            HStack(alignment: .center, spacing: 8) {
                // 回形针按钮
                AttachmentButton(viewModel: viewModel)
                
                // 文本输入框
                TextField("消息", text: $viewModel.draft, axis: .vertical)
                    .focused($viewModel.isInputFocused)
                    .lineLimit(1...5)
                    .font(.system(size: 17))
                    .multilineTextAlignment(.leading)
                
                // 表情按钮
                EmojiButton(viewModel: viewModel)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, viewModel.mediaPreviewItems.isEmpty ? 0 : 8)
            .frame(minHeight: ChatViewModel.composerButtonSize)
        }
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))
    }
}

// MARK: - 附件按钮

private struct AttachmentButton: View {
    @Bindable var viewModel: ChatViewModel
    
    var body: some View {
        PhotosPicker(
            selection: $viewModel.selectedMediaItems,
            maxSelectionCount: 9,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        ) {
            Image(systemName: viewModel.mediaBusy ? "hourglass" : "paperclip")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(viewModel.mediaBusy ? DS.Palette.textSecondary.opacity(0.6) : DS.Palette.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PressableStyle())
        .disabled(viewModel.mediaBusy)
    }
}

// MARK: - 表情按钮

private struct EmojiButton: View {
    @Bindable var viewModel: ChatViewModel
    
    var body: some View {
        Button {
            Haptics.light()
            viewModel.toggleStickerPanel()
        } label: {
            Image(systemName: viewModel.showStickerPanel ? "keyboard" : "face.smiling")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(viewModel.showStickerPanel ? DS.Palette.accent : DS.Palette.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 右侧按钮（语音/发送/录音）

private struct RightButton: View {
    @Bindable var viewModel: ChatViewModel
    @EnvironmentObject private var store: ChatStore
    
    private let buttonSize = ChatViewModel.composerButtonSize
    
    var body: some View {
        Group {
            switch viewModel.rightButtonType {
            case .voice:
                Image(systemName: "mic")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: buttonSize, height: buttonSize)
                    .dsGlassInteractive(in: Circle())
                    .contentShape(Circle())
                    .gesture(longPressGesture)
                
            case .send:
                Button {
                    handleSend()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .background(DS.Palette.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(PressableStyle())
                
            case .recording(let cancelled):
                Image(systemName: cancelled ? "trash.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(cancelled ? Color.red : DS.Palette.accent)
                    .clipShape(Circle())
                    .scaleEffect(cancelled ? 1.12 : 1.0)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: viewModel.rightButtonType)
    }
    
    private var longPressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard viewModel.draft.isEmpty && viewModel.mediaPreviewItems.isEmpty else { return }
                if !viewModel.isRecording {
                    startRecording()
                }
                guard viewModel.isRecording else { return }
                viewModel.dragTranslation = value.translation.width
                let shouldCancel = viewModel.dragTranslation < ChatViewModel.cancelDragThreshold
                if shouldCancel != viewModel.recordingCancelled {
                    viewModel.recordingCancelled = shouldCancel
                    Haptics.medium()
                }
            }
            .onEnded { _ in
                if !viewModel.draft.isEmpty {
                    handleSend()
                    return
                }
                guard viewModel.isRecording else { return }
                finishRecording(cancelled: viewModel.recordingCancelled)
            }
    }
    
    private func handleSend() {
        Haptics.light()
        
        // 发送图片
        if !viewModel.mediaPreviewItems.isEmpty {
            sendMediaItems()
            return
        }
        
        // 发送文字
        let text = viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        let replyId = viewModel.replyTarget?.id
        let previewText = viewModel.replyTarget.map { replyPreview(for: $0) }
        
        viewModel.draft = ""
        viewModel.clearReplyTarget()
        
        store.sendText(text, channel: channel, replyTo: replyId, replyPreview: previewText)
    }
    
    private func sendMediaItems() {
        let items = viewModel.mediaPreviewItems
        viewModel.clearPreviewItems()
        viewModel.mediaBusy = true
        
        Task {
            for item in items {
                guard let data = try? await item.item.loadTransferable(type: Data.self) else { continue }
                
                let mimeType: String
                let messageType: String
                
                // 简单判断类型
                if let uiImage = UIImage(data: data), let jpegData = uiImage.jpegData(compressionQuality: 0.8) {
                    mimeType = "image/jpeg"
                    messageType = "image"
                    _ = jpegData // 使用 jpegData
                } else {
                    mimeType = "application/octet-stream"
                    messageType = "file"
                }
                
                store.sendMedia(
                    data: data,
                    mimeType: mimeType,
                    preferredType: messageType,
                    localPreviewURL: nil,
                    channel: channel
                )
                
                // 间隔一下，避免太快
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            viewModel.mediaBusy = false
        }
    }
    
    private func replyPreview(for message: ChatMessage) -> String {
        let body: String
        switch message.type {
        case "sticker": body = "[表情]"
        case "image": body = "[图片]"
        case "video": body = "[视频]"
        case "file": body = "[文件]"
        default: body = message.displayText
        }
        return "\(message.senderName): \(body)"
    }
    
    // MARK: - 录音
    
    private func startRecording() {
        guard !viewModel.isRecording else { return }
        viewModel.isRecording = true
        viewModel.recordingCancelled = false
        viewModel.recordingElapsed = 0
        viewModel.dragTranslation = 0
        Haptics.light()
        
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecorder()
        case .denied:
            viewModel.isRecording = false
            viewModel.showMicPermissionAlert = true
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                await MainActor.run {
                    guard viewModel.isRecording else { return }
                    if granted {
                        startRecorder()
                    } else {
                        viewModel.isRecording = false
                        viewModel.showMicPermissionAlert = true
                    }
                }
            }
        @unknown default:
            viewModel.isRecording = false
        }
    }
    
    private func startRecorder() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            viewModel.isRecording = false
            return
        }
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingPath = documentsPath.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        viewModel.recordingURL = recordingPath
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            viewModel.audioRecorder = try AVAudioRecorder(url: recordingPath, settings: settings)
            viewModel.audioRecorder?.record()
            viewModel.recordingStartDate = Date()
            
            viewModel.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in
                    guard let startDate = viewModel.recordingStartDate else { return }
                    viewModel.recordingElapsed = Date().timeIntervalSince(startDate)
                }
            }
            
            viewModel.recordingPulse = true
        } catch {
            viewModel.isRecording = false
        }
    }
    
    private func finishRecording(cancelled: Bool) {
        viewModel.recordingTimer?.invalidate()
        viewModel.recordingTimer = nil
        viewModel.audioRecorder?.stop()
        viewModel.audioRecorder = nil
        viewModel.recordingPulse = false
        
        let elapsed = viewModel.recordingElapsed
        let url = viewModel.recordingURL
        
        viewModel.isRecording = false
        viewModel.recordingCancelled = false
        viewModel.recordingElapsed = 0
        viewModel.dragTranslation = 0
        viewModel.recordingStartDate = nil
        viewModel.recordingURL = nil
        
        guard !cancelled, elapsed >= 1.0, let url = url else { return }
        
        // 发送语音
        if let data = try? Data(contentsOf: url) {
            store.sendMedia(
                data: data,
                mimeType: "audio/m4a",
                preferredType: "voice",
                localPreviewURL: url,
                channel: channel
            )
        }
        
        // 删除临时文件
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 录音栏

private struct RecordingBar: View {
    @Bindable var viewModel: ChatViewModel
    
    private var recordingTimeLabel: String {
        let total = Int(viewModel.recordingElapsed.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(viewModel.recordingPulse ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: viewModel.recordingPulse)
            
            Text(recordingTimeLabel)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.Palette.textPrimary)
            
            Spacer(minLength: 8)
            
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("滑动取消")
                    .font(.system(size: 14))
            }
            .foregroundStyle(viewModel.recordingCancelled ? .red : DS.Palette.textSecondary)
            .offset(x: min(0, viewModel.dragTranslation * 0.4))
        }
        .padding(.horizontal, 16)
        .frame(height: ChatViewModel.composerButtonSize)
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))
    }
}

// MARK: - 图片预览行

private struct MediaPreviewRow: View {
    @Bindable var viewModel: ChatViewModel
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.mediaPreviewItems) { item in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        Button {
                            viewModel.removePreviewItem(item)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, DS.Palette.textSecondary.opacity(0.5))
                        }
                        .offset(x: 3, y: -3)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 8)
        }
        .frame(height: 64)
    }
}
