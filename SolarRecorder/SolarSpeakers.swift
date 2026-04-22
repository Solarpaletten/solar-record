// SolarRecorder/SolarRecorder/SolarSpeakers.swift
// Изолированный модуль определения спикеров.
// Не изменяет стабильную базу — только добавляется в проект.
// Подключается точечно: кнопка в RecordingRow + .sheet(SpeakersSheet).

import Foundation
import SwiftUI
import Combine

// ═══════════════════════════════════════════════════════
// MARK: - SpeakerSegment  (модель результата)
// ═══════════════════════════════════════════════════════

struct SpeakerSegment: Identifiable, Codable {
    let id: UUID
    let speaker: String   // "Speaker 1", "Speaker 2", ...
    let text: String

    init(speaker: String, text: String) {
        self.id      = UUID()
        self.speaker = speaker
        self.text    = text
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - SpeakersService
// ═══════════════════════════════════════════════════════

final class SpeakersService: ObservableObject {

    @Published var isDetecting: Bool = false
    @Published var segments: [SpeakerSegment] = []
    @Published var errorMessage: String? = nil

    private var currentRecordingID: UUID? = nil

    private static var backendURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SOLAR_BACKEND_URL") as? String
            ?? "http://localhost:3000/api/ai"
    }

    // MARK: - Detect

    func detect(recording: Recording) {
        guard !isDetecting else { return }
        guard let text = recording.transcript, !text.isEmpty else {
            errorMessage = "Нет транскрипции для анализа"
            return
        }

        isDetecting = true
        errorMessage = nil
        currentRecordingID = recording.id

        Task {
            do {
                let result = try await requestSpeakers(text: text)
                await MainActor.run {
                    self.segments = result
                    self.isDetecting = false
                    // Sidecar — сохраняем рядом с WAV
                    self.saveSidecar(result, wavURL: recording.url)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isDetecting = false
                }
            }
        }
    }

    func loadIfExists(for recording: Recording) {
        let url = sidecarURL(for: recording.url)
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([SpeakerSegment].self, from: data)
        else { return }
        segments = saved
    }

    func reset() {
        segments = []
        errorMessage = nil
    }

    // MARK: - Network

    private func requestSpeakers(text: String) async throws -> [SpeakerSegment] {
        guard let url = URL(string: Self.backendURL) else {
            throw SpeakersError.invalidURL
        }

        let body: [String: Any] = [
            "type": "speakers",
            "payload": ["text": text]
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SpeakersError.serverError(msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String
        else { throw SpeakersError.invalidResponse }

        return parseSpeakers(result)
    }

    // MARK: - Parser
    // Backend возвращает формат:
    // [Speaker 1]: текст текст текст
    // [Speaker 2]: текст текст текст

    private func parseSpeakers(_ raw: String) -> [SpeakerSegment] {
        var segments: [SpeakerSegment] = []
        let lines = raw.components(separatedBy: "\n")
        let pattern = #"^\[(.+?)\]:\s*(.+)$"#

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.range(of: pattern, options: .regularExpression) != nil,
               let match = trimmed.firstMatch(pattern: pattern) {
                segments.append(SpeakerSegment(speaker: match.speaker, text: match.text))
            } else if !segments.isEmpty {
                // Продолжение предыдущего спикера
                let last = segments.removeLast()
                segments.append(SpeakerSegment(speaker: last.speaker,
                                               text: last.text + " " + trimmed))
            }
        }
        return segments
    }

    // MARK: - Sidecar (.speakers)

    private func sidecarURL(for wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("speakers")
    }

    private func saveSidecar(_ segments: [SpeakerSegment], wavURL: URL) {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: sidecarURL(for: wavURL))
    }
}

// MARK: - Regex helper

private extension String {
    func firstMatch(pattern: String) -> (speaker: String, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self,
                                           range: NSRange(self.startIndex..., in: self)),
              match.numberOfRanges == 3,
              let r1 = Range(match.range(at: 1), in: self),
              let r2 = Range(match.range(at: 2), in: self)
        else { return nil }
        return (String(self[r1]), String(self[r2]))
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - SpeakersError
// ═══════════════════════════════════════════════════════

enum SpeakersError: Error, LocalizedError {
    case invalidURL
    case serverError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Неверный URL backend"
        case .serverError(let m):   return "Ошибка сервера: \(m)"
        case .invalidResponse:      return "Неверный ответ от сервера"
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - SpeakersSheet  (UI)
// ═══════════════════════════════════════════════════════

struct SpeakersSheet: View {
    let recording: Recording
    @Environment(\.dismiss) var dismiss
    @StateObject private var service = SpeakersService()

    // Цвета для спикеров (циклически)
    private let speakerColors: [Color] = [.blue, .green, .orange, .purple, .cyan, .pink]

    private func color(for speaker: String) -> Color {
        let index = abs(speaker.hashValue) % speakerColors.count
        return speakerColors[index]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    if service.isDetecting {
                        detectingView
                    } else if let err = service.errorMessage {
                        errorView(err)
                    } else if service.segments.isEmpty {
                        emptyView
                    } else {
                        segmentsView
                    }
                }
            }
            .navigationTitle("Спикеры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !service.segments.isEmpty {
                        Button {
                            service.reset()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundColor(.gray)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }.foregroundColor(.red)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            service.loadIfExists(for: recording)
            if service.segments.isEmpty {
                service.detect(recording: recording)
            }
        }
    }

    // MARK: - Sub-views

    private var detectingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.blue).scaleEffect(1.4)
            Text("Определяю спикеров...")
                .font(.system(size: 14)).foregroundColor(.gray)
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32)).foregroundColor(.red.opacity(0.7))
            Text(msg)
                .font(.system(size: 14)).foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Повторить") { service.detect(recording: recording) }
                .foregroundColor(.blue)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 32)).foregroundColor(.gray.opacity(0.5))
            Text("Спикеры не найдены")
                .font(.system(size: 14)).foregroundColor(.gray)
        }
    }

    private var segmentsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {

                // Легенда
                let speakers = Array(Set(service.segments.map(\.speaker))).sorted()
                HStack(spacing: 12) {
                    ForEach(speakers, id: \.self) { sp in
                        HStack(spacing: 5) {
                            Circle().fill(color(for: sp)).frame(width: 8, height: 8)
                            Text(sp).font(.system(size: 11)).foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                Divider().background(Color.white.opacity(0.1))
                    .padding(.horizontal, 20)

                // Сегменты
                ForEach(service.segments) { seg in
                    HStack(alignment: .top, spacing: 12) {
                        // Цветная метка спикера
                        VStack {
                            Circle()
                                .fill(color(for: seg.speaker))
                                .frame(width: 8, height: 8)
                                .padding(.top, 6)
                            Spacer()
                        }
                        .frame(width: 8)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(seg.speaker)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(color(for: seg.speaker))
                            Text(seg.text)
                                .font(.system(size: 14)).lineSpacing(4)
                                .foregroundColor(.white.opacity(0.85))
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                    Divider().background(Color.white.opacity(0.07))
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 20)
        }
    }
}
