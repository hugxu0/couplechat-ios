import Foundation

struct VoiceTranscriptRepository {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetch(messageId: String, token: String) async throws -> VoiceTranscript? {
        do {
            let data = try await request(path: path(messageId), token: token)
            return try decode(data, messageId: messageId)
        } catch V2RepositoryError.server(let code) where code == 404 {
            return nil
        }
    }

    func retry(messageId: String, token: String) async throws -> VoiceTranscript {
        let data = try await request(
            path: "\(path(messageId))/retry", method: "POST", token: token)
        return try decode(data, messageId: messageId)
    }

    func correct(messageId: String, text: String, baseVersion: Int, token: String) async throws -> VoiceTranscript {
        let body = try JSONEncoder().encode(CorrectionMutation(text: text, baseVersion: baseVersion))
        let data = try await request(path: path(messageId), method: "PATCH", body: body, token: token)
        return try decode(data, messageId: messageId)
    }

    private func decode(_ data: Data, messageId: String) throws -> VoiceTranscript {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(TranscriptEnvelope.self, from: data),
           let transcript = envelope.transcript {
            return transcript.messageId.isEmpty ? transcript.withMessageId(messageId) : transcript
        }
        let transcript = try decoder.decode(VoiceTranscript.self, from: data)
        return transcript.messageId.isEmpty ? transcript.withMessageId(messageId) : transcript
    }

    private func request(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        token: String
    ) async throws -> Data {
        guard let url = URL(string: path, relativeTo: ServerConfig.baseURL)?.absoluteURL else {
            throw V2RepositoryError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await httpClient.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw V2RepositoryError.invalidResponse
        }
        if code == 409,
           let envelope = try? JSONDecoder().decode(TranscriptEnvelope.self, from: data),
           let transcript = envelope.transcript {
            throw V2RepositoryError.transcriptConflict(transcript)
        }
        // Older servers returned the authoritative `.unavailable` transcript with 503.
        // Preserve that state instead of letting the presentation layer rewrite it as failed.
        if code == 503,
           let envelope = try? JSONDecoder().decode(TranscriptEnvelope.self, from: data),
           envelope.transcript != nil {
            return data
        }
        guard (200..<300).contains(code) else { throw V2RepositoryError.server(code) }
        return data
    }

    private func path(_ messageId: String) -> String {
        "api/v2/messages/\(messageId)/transcript"
    }
}

private extension VoiceTranscriptRepository {
    struct TranscriptEnvelope: Decodable { let transcript: VoiceTranscript? }
    struct CorrectionMutation: Encodable { let text: String; let baseVersion: Int }
}

private extension VoiceTranscript {
    func withMessageId(_ messageId: String) -> VoiceTranscript {
        VoiceTranscript(
            messageId: messageId, status: status, text: text, language: language,
            confidence: confidence, errorMessage: errorMessage,
            updatedAt: updatedAt, version: version)
    }
}
