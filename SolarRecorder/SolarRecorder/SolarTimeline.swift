// SolarRecorder/SolarRecorder/SolarTimeline.swift
// Изолированный модуль timeline v1.
// Хронологическая разбивка транскрипта с временными метками.
// Не изменяет стабильную базу — только добавляется в проект.

import Foundation
import SwiftUI

// ═══════════════════════════════════════════════════════
// MARK: - TimelineSegment  (модель)
// ═══════════════════════════════════════════════════════

struct TimelineSegment: Identifiable, Codable {
    let id: UUID
    let timestamp: TimeInterval   // секунды от начала записи
    let speaker: String?          // nil если speakers не запускались
    let text: String
    let translatedText: String?   // nil если перевод не запускался

    init(timestamp: TimeInterval,
         speaker: String? = nil,
         text: String,
         translatedText: String? = nil) {
        self.id            = UUID()
        self.timestamp     = timestamp
        self.speaker       = speaker
        self.text          = text
        self.translatedText = translatedText
    }

    var formattedTimestamp: String {
        let m = Int(timestamp) / 60
        let s = Int(timestamp) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - TimelineService
// ═══════════════════════════════════════════════════════

final class TimelineService: ObservableObject {

    @Published var isGenerating: Bool = false
    @Published var segments: [TimelineSegment] = []
    @Published var errorMessage: String? = nil

    private static var backendURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SOLAR_BACKEND_URL") as? String
            ?? "http://localhost:3000/api/ai"
    }

    // MARK: - Public API

    func generate(for recording: Recording) {
        guard !isGenerating else { return }
        guard let text = recording.transcript, !text.isEmpty else {
            errorMessage = "Нет транскрипции для построения timeline"
            return
        }

        isGenerating = true
        errorMessage = nil

        // Загружаем speakers из sidecar если есть
        let speakerMap = loadSpeakerSidecar(for: recording)

        Task {
            do {
                let result = try await requestTimeline(
                    text: text,
                    duration: recording.duration,
                    speakerMap: speakerMap
                )
                await MainActor.run {
                    self.segments = result
                    self.isGenerating = false
                    self.saveSidecar(result, wavURL: recording.url)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGenerating = false
                }
            }
        }
    }

    func loadIfExists(for recording: Recording) {
        let url = sidecarURL(for: recording.url)
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([TimelineSegment].self, from: data)
        else { return }
        segments = saved
    }

    func reset() {
        segments = []
        errorMessage = nil
    }

    // MARK: - Network

    private func requestTimeline(text: String,
                                  duration: TimeInterval,
                                  speakerMap: [String]) async throws -> [TimelineSegment] {
        guard let url = URL(string: Self.backendURL) else {
            throw TimelineError.invalidURL
        }

        var payload: [String: Any] = [
            "text": text,
            "duration": duration
        ]
        if !speakerMap.isEmpty {
            payload["speakers"] = speakerMap
        }

        let body: [String: Any] = ["type": "timeline", "payload": payload]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw TimelineError.serverError(msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String
        else { throw TimelineError.invalidResponse }

        return parseTimeline(result)
    }

    // MARK: - Parser
    // Backend возвращает формат:
    // [MM:SS] текст сегмента
    // [MM:SS] [Speaker N] текст сегмента  (если speakers были переданы)

    private func parseTimeline(_ raw: String) -> [TimelineSegment] {
        var result: [TimelineSegment] = []
        let lines = raw.components(separatedBy: "\n")

        // Паттерн: [MM:SS] или [MM:SS] [Speaker N]: текст
        let tsPattern      = #"^\[(\d+):(\d+)\]\s*(.+)$"#
        let speakerPattern = #"^\[Speaker\s+(\d+)\]:\s*(.+)$"#

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let (minutes, seconds, rest) = extractTimestamp(trimmed, pattern: tsPattern)
            else { continue }

            let ts = TimeInterval(minutes * 60 + seconds)

            // Проверяем есть ли speaker в rest
            if let (spNum, spText) = extractSpeaker(rest, pattern: speakerPattern) {
                result.append(TimelineSegment(
                    timestamp: ts,
                    speaker: "Speaker \(spNum)",
                    text: spText
                ))
            } else {
                result.append(TimelineSegment(
                    timestamp: ts,
                    speaker: nil,
                    text: rest.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return result
    }

    private func extractTimestamp(_ s: String, pattern: String) -> (Int, Int, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              match.numberOfRanges == 4,
              let r1 = Range(match.range(at: 1), in: s),
              let r2 = Range(match.range(at: 2), in: s),
              let r3 = Range(match.range(at: 3), in: s),
              let minutes = Int(s[r1]),
              let seconds = Int(s[r2])
        else { return nil }
        return (minutes, seconds, String(s[r3]))
    }

    private func extractSpeaker(_ s: String, pattern: String) -> (Int, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              match.numberOfRanges == 3,
              let r1 = Range(match.range(at: 1), in: s),
              let r2 = Range(match.range(at: 2), in: s),
              let num = Int(s[r1])
        else { return nil }
        return (num, String(s[r2]))
    }

    // MARK: - Speakers sidecar (read-only, из SolarSpeakers)

    private func loadSpeakerSidecar(for recording: Recording) -> [String] {
        let url = recording.url.deletingPathExtension().appendingPathExtension("speakers")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([[String: String]].self, from: data)
        else { return [] }
        // Извлекаем уникальные имена спикеров для контекста
        return Array(Set(json.compactMap { $0["speaker"] })).sorted()
    }

    // MARK: - Sidecar (.timeline)

    private func sidecarURL(for wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("timeline")
    }

    private func saveSidecar(_ segments: [TimelineSegment], wavURL: URL) {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: sidecarURL(for: wavURL))
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - TimelineError
// ═══════════════════════════════════════════════════════

enum TimelineError: Error, LocalizedError {
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
// MARK: - TimelineSheet  (UI)
// ═══════════════════════════════════════════════════════

struct TimelineSheet: View {
    let recording: Recording
    @Environment(\.dismiss) var dismiss
    @StateObject private var service = TimelineService()

    private let speakerColors: [Color] = [.blue, .green, .orange, .purple, .cyan, .pink]

    private func color(for speaker: String?) -> Color {
        guard let sp = speaker else { return .gray }
        return speakerColors[abs(sp.hashValue) % speakerColors.count]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    if service.isGenerating {
                        generatingView
                    } else if let err = service.errorMessage {
                        errorView(err)
                    } else if service.segments.isEmpty {
                        emptyView
                    } else {
                        segmentsView
                    }
                }
            }
            .navigationTitle("Timeline")
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
                service.generate(for: recording)
            }
        }
    }

    // MARK: - Sub-views

    private var generatingView: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.blue).scaleEffect(1.4)
            Text("Строю timeline...")
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
            Button("Повторить") { service.generate(for: recording) }
                .foregroundColor(.blue)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 32)).foregroundColor(.gray.opacity(0.5))
            Text("Timeline пуст")
                .font(.system(size: 14)).foregroundColor(.gray)
        }
    }

    private var segmentsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(service.segments) { seg in
                    HStack(alignment: .top, spacing: 12) {

                        // Временная метка
                        Text(seg.formattedTimestamp)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange.opacity(0.8))
                            .frame(width: 42, alignment: .leading)
                            .padding(.top, 2)

                        // Вертикальная линия таймлайна
                        VStack(spacing: 0) {
                            Circle()
                                .fill(color(for: seg.speaker))
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)
                            Rectangle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 1)
                        }

                        // Контент
                        VStack(alignment: .leading, spacing: 4) {
                            if let speaker = seg.speaker {
                                Text(speaker)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(color(for: speaker))
                            }
                            Text(seg.text)
                                .font(.system(size: 14)).lineSpacing(3)
                                .foregroundColor(.white.opacity(0.85))
                                .textSelection(.enabled)
                            if let translated = seg.translatedText {
                                Text(translated)
                                    .font(.system(size: 12)).lineSpacing(3)
                                    .foregroundColor(.white.opacity(0.5))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.bottom, 16)

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, 20)
        }
    }
}
