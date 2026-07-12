import UIKit

extension ChatViewController {
    @objc func persistentSyncDidChange(_ notification: Notification) {
        guard notification.persistentSyncIncludes(["message_transcript"]),
              let token = store.session?.token else { return }
        let messageIDs = timelineController.loadedTranscriptMessageIDs()
        guard !messageIDs.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for messageID in messageIDs {
                do {
                    if let transcript = try await voiceTranscriptRepository.fetch(
                        messageId: messageID, token: token) {
                        timelineController.applyTranscript(transcript, messageId: messageID)
                    }
                } catch {
                    continue
                }
            }
        }
    }

    func handleTranscriptTap(_ message: ChatMessage) {
        guard message.type == "voice",
              let token = store.session?.token else { return }
        let current = timelineController.transcript(for: message.id)
        if current?.status == .ready {
            timelineController.toggleTranscript(messageId: message.id)
            return
        }
        if current?.status == .processing || current?.status == .queued { return }
        timelineController.applyTranscript(.processing(messageId: message.id), messageId: message.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await initialTranscript(
                    messageId: message.id,
                    retries: current?.status == .failed || current?.status == .unavailable,
                    token: token)
                timelineController.applyTranscript(
                    transcript, messageId: message.id, expands: transcript.status == .ready)
                if transcript.status == .queued || transcript.status == .processing {
                    await pollTranscript(messageId: message.id, token: token)
                }
            } catch {
                let failed = VoiceTranscript(
                    messageId: message.id,
                    status: .failed,
                    errorMessage: error.localizedDescription)
                timelineController.applyTranscript(failed, messageId: message.id)
            }
        }
    }

    func presentTranscriptCorrection(_ message: ChatMessage) {
        guard let transcript = timelineController.transcript(for: message.id),
              transcript.status == .ready,
              let text = transcript.text,
              let token = store.session?.token else { return }
        let alert = UIAlertController(
            title: "纠正转写",
            message: "修改后会同步到你们的其他设备。",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.clearButtonMode = .whileEditing
            field.accessibilityLabel = "转写文字"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let corrected = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !corrected.isEmpty else { return }
            Task { await self.correctTranscript(messageId: message.id, text: corrected, token: token) }
        })
        present(alert, animated: true)
    }

    private func initialTranscript(
        messageId: String,
        retries: Bool,
        token: String
    ) async throws -> VoiceTranscript {
        if retries {
            return try await voiceTranscriptRepository.retry(messageId: messageId, token: token)
        }
        if let existing = try await voiceTranscriptRepository.fetch(messageId: messageId, token: token),
           existing.status != .none {
            return existing
        }
        return try await voiceTranscriptRepository.retry(messageId: messageId, token: token)
    }

    private func pollTranscript(messageId: String, token: String) async {
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            do {
                guard let transcript = try await voiceTranscriptRepository.fetch(
                    messageId: messageId, token: token) else { continue }
                timelineController.applyTranscript(
                    transcript, messageId: messageId, expands: transcript.status == .ready)
                if transcript.status == .ready || transcript.status == .failed || transcript.status == .unavailable { return }
            } catch {
                return
            }
        }
    }

    private func correctTranscript(messageId: String, text: String, token: String) async {
        do {
            let transcript = try await voiceTranscriptRepository.correct(
                messageId: messageId,
                text: text,
                baseVersion: timelineController.transcript(for: messageId)?.version ?? 0,
                token: token)
            timelineController.applyTranscript(transcript, messageId: messageId, expands: true)
        } catch V2RepositoryError.transcriptConflict(let current) {
            timelineController.applyTranscript(current, messageId: messageId, expands: true)
            let alert = UIAlertController(
                title: "已载入最新转写",
                message: V2RepositoryError.transcriptConflict(current).localizedDescription,
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        } catch {
            let alert = UIAlertController(title: "保存失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            present(alert, animated: true)
        }
    }
}
