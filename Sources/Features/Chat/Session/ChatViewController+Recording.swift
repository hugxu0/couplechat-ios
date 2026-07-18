import AVFoundation
import UIKit

private enum ChatRecordingPolicy {
    static let maximumDuration: TimeInterval = 10 * 60
}

extension ChatViewController {
    func beginRecording() {
        guard !isRecording else { return }
        guard isForegroundWindowActive else {
            inputState = .idle
            composer.clearRecording()
            return
        }
        let requestID = UUID()
        recordingRequestID = requestID
        isRecording = true
        recordingCancelled = false
        recordingElapsed = 0
        Haptics.light()

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecorder(requestID: requestID)
        case .denied:
            failRecordingRequest(requestID)
            showMicPermissionAlert()
        case .undetermined:
            Task { [weak self] in
                let granted = await AVAudioApplication.requestRecordPermission()
                guard let self,
                      recordingRequestID == requestID,
                      isRecording else { return }
                guard granted else {
                    failRecordingRequest(requestID)
                    showMicPermissionAlert()
                    return
                }
                startRecorder(requestID: requestID)
            }
        @unknown default:
            failRecordingRequest(requestID)
        }
    }

    private func startRecorder(requestID: UUID) {
        guard recordingRequestID == requestID,
              isRecording else { return }
        guard isForegroundWindowActive else {
            failRecordingRequest(requestID)
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            failRecordingRequest(requestID)
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
            failRecordingRequest(requestID)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            failRecordingRequest(requestID)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }
        audioRecorder = recorder
        recordingURL = url
        recordingStartDate = Date()
        composer.setRecording(elapsed: 0, cancelled: false)

        recordingTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(recordingTimerDidFire(_:)),
            userInfo: nil,
            repeats: true)
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func recordingTimerDidFire(_ timer: Timer) {
        guard timer === recordingTimer,
              isRecording,
              let start = recordingStartDate else { return }
        recordingElapsed = min(
            Date().timeIntervalSince(start),
            ChatRecordingPolicy.maximumDuration)
        if recordingElapsed >= ChatRecordingPolicy.maximumDuration {
            inputState = .idle
            finishRecording(cancelled: false)
            return
        }
        audioRecorder?.updateMeters()
        let power = audioRecorder?.averagePower(forChannel: 0) ?? -45
        let level = CGFloat(max(0.05, min(1, (power + 45) / 45)))
        composer.setRecording(
            elapsed: recordingElapsed,
            cancelled: recordingCancelled,
            level: level)
    }

    @objc func audioSessionWasInterrupted(_ notification: Notification) {
        guard let rawValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
              AVAudioSession.InterruptionType(rawValue: rawValue) == .began else { return }
        cancelRecordingForInterruption()
    }

    @objc func audioSessionRouteChanged(_ notification: Notification) {
        guard isRecording || recordingRequestID != nil || audioRecorder != nil,
              let rawValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else { return }
        switch reason {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            cancelRecordingForInterruption()
        default:
            break
        }
    }

    func finishRecording(cancelled: Bool) {
        recordingRequestID = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        let duration = recordingElapsed
        let url = recordingURL
        audioRecorder?.stop()
        audioRecorder = nil
        recordingURL = nil
        recordingStartDate = nil
        isRecording = false
        recordingCancelled = false
        recordingElapsed = 0
        composer.clearRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard !cancelled, duration >= 1.0, let url else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        stickToLatestAfterNextReload = true
        store.sendMediaFile(
            fileURL: url,
            mimeType: "audio/m4a",
            preferredType: "voice",
            localPreviewURL: url,
            channel: channel,
            durationMs: min(600_000, max(1, Int((duration * 1_000).rounded()))),
            removeSourceAfterPersist: true)
    }

    private func failRecordingRequest(_ requestID: UUID) {
        guard recordingRequestID == requestID else { return }
        recordingRequestID = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioRecorder?.stop()
        audioRecorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        recordingStartDate = nil
        isRecording = false
        recordingCancelled = false
        recordingElapsed = 0
        inputState = .idle
        composer.clearRecording()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
