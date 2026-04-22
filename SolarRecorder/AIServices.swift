import Foundation
import Combine

// ═══════════════════════════════════════════════════════
// MARK: - SummaryMode
// ═══════════════════════════════════════════════════════

enum SummaryMode: String {
    case standard = "standard"
    case legal    = "legal"
    case erp      = "erp"
    case action   = "action"
}

// ═══════════════════════════════════════════════════════
// MARK: - AIService Protocol
// ═══════════════════════════════════════════════════════
// Единый интерфейс — можно подменить на Mock или Local

protocol AIService {
    func transcribe(fileURL: URL) async throws -> TranscribeResult
    func translate(text: String, targetLang: String, detectedLang: String?) async throws -> TranslateResult
    func summarize(text: String, mode: SummaryMode) async throws -> String
}

struct TranscribeResult {
    let text: String
    let language: String?
}

struct TranslateResult {
    let text: String
    let targetLang: String
}

// ═══════════════════════════════════════════════════════
// MARK: - SolarBackendService  (iOS → наш Next.js proxy)
// ═══════════════════════════════════════════════════════

class SolarBackendService: AIService {

    // Локально: http://192.168.X.X:3000/api/ai
    // Продакшн: https://solar-ai-backend.vercel.app/api/ai
    static var baseURL: String = {
        // Сначала проверяем Info.plist
        let plist = Bundle.main.object(forInfoDictionaryKey: "SOLAR_BACKEND_URL") as? String
        return plist ?? "http://localhost:3000/api/ai"
    }()

    private var endpoint: URL {
        URL(string: Self.baseURL)!
    }

    // MARK: - Transcribe

    func transcribe(fileURL: URL) async throws -> TranscribeResult {
        let audioData = try Data(contentsOf: fileURL)
        let base64 = audioData.base64EncodedString()

        let body: [String: Any] = [
            "type": "transcribe",
            "payload": ["file": base64]
        ]

        let response = try await post(body: body)

        guard let result = response["result"] as? String else {
            throw AIError.invalidResponse
        }
        let lang = response["language"] as? String
        return TranscribeResult(text: result, language: lang)
    }

    // MARK: - Translate

    func translate(text: String, targetLang: String = "auto",
                   detectedLang: String? = nil) async throws -> TranslateResult {
        var payload: [String: Any] = [
            "text": text,
            "targetLang": targetLang
        ]
        if let lang = detectedLang { payload["detectedLang"] = lang }

        let body: [String: Any] = ["type": "translate", "payload": payload]
        let response = try await post(body: body)

        guard let result = response["result"] as? String else {
            throw AIError.invalidResponse
        }
        let tl = response["targetLang"] as? String ?? targetLang
        return TranslateResult(text: result, targetLang: tl)
    }

    // MARK: - Summarize

    func summarize(text: String, mode: SummaryMode = .standard) async throws -> String {
        let body: [String: Any] = [
            "type": "summary",
            "payload": ["text": text, "mode": mode.rawValue]
        ]
        let response = try await post(body: body)

        guard let result = response["result"] as? String else {
            throw AIError.invalidResponse
        }
        return result
    }

    // MARK: - HTTP helper

    private func post(body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw AIError.networkError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIError.serverError(http.statusCode, msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.invalidResponse
        }
        if let error = json["error"] {
            throw AIError.serverError(0, "\(error)")
        }
        return json
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - AIError
// ═══════════════════════════════════════════════════════

enum AIError: Error, LocalizedError {
    case networkError(String)
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .networkError(let m):      return "Network error: \(m)"
        case .serverError(let c, let m): return "Server error \(c): \(m)"
        case .invalidResponse:          return "Invalid response from server"
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - Updated WhisperService  (через backend)
// ═══════════════════════════════════════════════════════

class WhisperService: ObservableObject {
    @Published var transcribingID: UUID? = nil

    private let ai: AIService = SolarBackendService()

    func transcribe(recording: Recording, store: RecordingsStore) {
        guard transcribingID == nil else { return }
        guard recording.transcript == nil else { return }  // уже есть
        transcribingID = recording.id

        Task {
            do {
                let result = try await ai.transcribe(fileURL: recording.url)
                await MainActor.run {
                    store.updateTranscript(result.text, summary: nil, for: recording.id)
                    store.updateDetectedLanguage(result.language, for: recording.id)
                    self.transcribingID = nil
                    NotificationCenter.default.post(name: .newRecordingSaved, object: nil)
                }
            } catch {
                print("Whisper error: \(error)")
                await MainActor.run { self.transcribingID = nil }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - Updated TranslationService  (через backend)
// ═══════════════════════════════════════════════════════

class TranslationService: ObservableObject {
    @Published var translatingIDs: Set<UUID> = []

    private let ai: AIService = SolarBackendService()

    func translate(recording: Recording, store: RecordingsStore) {
        guard !translatingIDs.contains(recording.id) else { return }
        guard let text = recording.transcript, !text.isEmpty else { return }

        translatingIDs.insert(recording.id)

        Task {
            do {
                // Авто-обратный перевод по определённому языку
                let result = try await ai.translate(
                    text: text,
                    targetLang: "auto",
                    detectedLang: recording.detectedLanguage
                )
                await MainActor.run {
                    store.updateTranslation(result.text, for: recording.id)
                    self.translatingIDs.remove(recording.id)
                }
            } catch {
                print("Translation error: \(error)")
                await MainActor.run { self.translatingIDs.remove(recording.id) }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - Updated SummaryService  (через backend)
// ═══════════════════════════════════════════════════════

class SummaryService: ObservableObject {
    @Published var summarizingIDs: Set<UUID> = []

    private let ai: AIService = SolarBackendService()

    func summarize(recording: Recording, store: RecordingsStore,
                   mode: SummaryMode = .standard) {
        guard !summarizingIDs.contains(recording.id) else { return }
        guard let text = recording.transcript, !text.isEmpty else { return }

        summarizingIDs.insert(recording.id)

        Task {
            do {
                let result = try await ai.summarize(text: text, mode: mode)
                await MainActor.run {
                    store.updateTranscript(text, summary: result, for: recording.id)
                    self.summarizingIDs.remove(recording.id)
                    NotificationCenter.default.post(name: .newRecordingSaved, object: nil)
                }
            } catch {
                print("Summary error: \(error)")
                await MainActor.run { self.summarizingIDs.remove(recording.id) }
            }
        }
    }
}
