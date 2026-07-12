import AVFoundation
import UIKit

extension ChatViewController {
    func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingCancelled = false
        recordingElapsed = 0
        Haptics.light()

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecorder()
        case .denied:
            isRecording = false
            showMicPermissionAlert()
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                if granted {
                    startRecorder()
                } else {
                    isRecording = false
                    showMicPermissionAlert()
                }
            }
        @unknown default:
            isRecording = false
        }
    }

    private func startRecorder() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            isRecording = false
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            isRecording = false
            return
        }
        recorder.isMeteringEnabled = true
        recorder.record()
        audioRecorder = recorder
        recordingURL = url
        recordingStartDate = Date()
        composer.setRecording(elapsed: 0, cancelled: false)

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recordingElapsed = Date().timeIntervalSince(self.recordingStartDate ?? Date())
                self.audioRecorder?.updateMeters()
                let power = self.audioRecorder?.averagePower(forChannel: 0) ?? -45
                let level = CGFloat(max(0.05, min(1, (power + 45) / 45)))
                self.composer.setRecording(elapsed: self.recordingElapsed, cancelled: self.recordingCancelled, level: level)
            }
        }
    }

    func finishRecording(cancelled: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        let duration = recordingElapsed
        let url = recordingURL
        audioRecorder?.stop()
        audioRecorder = nil
        recordingURL = nil
        isRecording = false
        recordingCancelled = false
        recordingElapsed = 0
        composer.clearRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard !cancelled, duration >= 1.0, let url, let data = try? Data(contentsOf: url) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        stickToLatestAfterNextReload = true
        store.sendMedia(data: data, mimeType: "audio/m4a", preferredType: "voice", localPreviewURL: url, channel: channel)
    }

    private func showMicPermissionAlert() {
        let alert = UIAlertController(title: "需要麦克风权限", message: "请在系统设置中允许访问麦克风，才能发送语音消息", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
}
