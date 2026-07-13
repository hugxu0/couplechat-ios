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

}
