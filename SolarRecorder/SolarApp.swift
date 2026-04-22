// SolarRecorder/SolarRecorder/SolarApp_v3.swift

import SwiftUI
import AVFoundation
import Accelerate
import Combine
import UIKit

// ═══════════════════════════════════════════════════════
// MARK: - WaveformData (генерируется при записи и при загрузке)
// ═══════════════════════════════════════════════════════

class WaveformData: ObservableObject {
    @Published var samples: [Float] = []
    private let targetCount = 200   // сколько баров в waveform

    // Добавляем семплы в реальном времени (при записи)
    func append(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(count))

        DispatchQueue.main.async {
            self.samples.append(rms)
            if self.samples.count > self.targetCount {
                self.samples.removeFirst()
            }
        }
    }

    // Загружаем из WAV файла (для плеера)
    func load(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  (try? file.read(into: buffer)) != nil,
                  let data = buffer.floatChannelData?[0] else { return }

            let total = Int(buffer.frameLength)
            let chunkSize = max(1, total / self.targetCount)
            var result: [Float] = []

            for i in 0..<self.targetCount {
                let start = i * chunkSize
                let end   = min(start + chunkSize, total)
                guard start < total else { result.append(0); continue }
                var rms: Float = 0
                vDSP_rmsqv(data + start, 1, &rms, vDSP_Length(end - start))
                result.append(rms)
            }

            // Normalize
            if let maxVal = result.max(), maxVal > 0 {
                result = result.map { $0 / maxVal }
            }

            DispatchQueue.main.async { self.samples = result }
        }
    }

    func reset() { samples = [] }
}

// ═══════════════════════════════════════════════════════
// MARK: - WaveformView
// ═══════════════════════════════════════════════════════

struct WaveformView: View {
    let samples: [Float]
    let progress: Double        // 0..1 — сколько прошло (для плеера)
    let color: Color
    let isLive: Bool            // true = при записи (анимация справа налево)

    var body: some View {
        GeometryReader { geo in
            let w    = geo.size.width
            let h    = geo.size.height
            let count = max(samples.count, 1)
            let barW  = (w / CGFloat(count)) * 0.6
            let gap   = (w / CGFloat(count)) * 0.4

            Canvas { ctx, size in
                for (i, sample) in samples.enumerated() {
                    let x      = CGFloat(i) * (barW + gap) + gap / 2
                    let barH   = max(2, CGFloat(sample) * h * 0.9)
                    let y      = (h - barH) / 2
                    let rect   = CGRect(x: x, y: y, width: barW, height: barH)
                    let path   = Path(roundedRect: rect, cornerRadius: barW / 2)

                    // Color: played = bright, upcoming = dim
                    let fraction = Double(i) / Double(count)
                    let alpha: Double = isLive
                        ? Double(sample) * 0.8 + 0.2
                        : (fraction <= progress ? 1.0 : 0.25)

                    ctx.fill(path, with: .color(color.opacity(alpha)))
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - Model
// ═══════════════════════════════════════════════════════

struct Recording: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
    let date: Date
    let duration: TimeInterval
    var transcript: String?     // nil = not yet transcribed
    var summary: String?
    var translation: String?    // nil = not yet translated
    var detectedLanguage: String? // "ru", "en", "de" — из Whisper

    var formattedDate: String {
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
        return f.string(from: date)
    }
    var formattedTime: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
    var formattedDuration: String {
        let m = Int(duration) / 60; let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - RecordingsStore
// ═══════════════════════════════════════════════════════

class RecordingsStore: ObservableObject {
    @Published var recordings: [Recording] = []

    private let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = docs.appendingPathComponent("SolarRecords", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    init() { load() }

    func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        recordings = files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .compactMap { url -> Recording? in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                // ✅ Fix #1: используем modificationDate если есть
                let date  = (attrs?[.modificationDate] as? Date)
                         ?? (attrs?[.creationDate] as? Date)
                         ?? Date()
                let dur   = audioDuration(url: url)

                // Load transcript from sidecar .txt if exists
                let txtURL = url.deletingPathExtension().appendingPathExtension("txt")
                let transcript = try? String(contentsOf: txtURL, encoding: .utf8)

                // Load summary from sidecar .md if exists
                let mdURL = url.deletingPathExtension().appendingPathExtension("md")
                let summary = try? String(contentsOf: mdURL, encoding: .utf8)

                var name = url.deletingPathExtension().lastPathComponent
                name = name.replacingOccurrences(of: "solar_", with: "")

                // Load translation from sidecar .translation.txt if exists
                let trURL = url.deletingPathExtension().appendingPathExtension("translation.txt")
                let translation = try? String(contentsOf: trURL, encoding: .utf8)

                // Load detected language from sidecar .lang if exists
                let langURL = url.deletingPathExtension().appendingPathExtension("lang")
                let detectedLanguage = try? String(contentsOf: langURL, encoding: .utf8)

                return Recording(url: url, name: name, date: date, duration: dur,
                                 transcript: transcript, summary: summary,
                                 translation: translation,
                                 detectedLanguage: detectedLanguage)
            }
            .sorted { $0.date > $1.date }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
        let base = recording.url.deletingPathExtension()
        for ext in ["json", "sha256", "txt", "md", "translation.txt", "lang", "speakers"] {
            try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
        }
        recordings.removeAll { $0.id == recording.id }
    }

    func updateTranscript(_ transcript: String, summary: String?, for id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].transcript = transcript
        recordings[idx].summary    = summary
        // Write sidecar files
        let base = recordings[idx].url.deletingPathExtension()
        try? transcript.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        if let s = summary {
            try? s.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
        }
    }

    func updateDetectedLanguage(_ lang: String?, for id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }),
              let lang = lang else { return }
        recordings[idx].detectedLanguage = lang
        let base = recordings[idx].url.deletingPathExtension()
        try? lang.write(to: base.appendingPathExtension("lang"),
                        atomically: true, encoding: .utf8)
    }

    func updateTranslation(_ text: String, for id: UUID) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[idx].translation = text
        let url = recordings[idx].url.deletingPathExtension().appendingPathExtension("translation.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .newRecordingSaved, object: nil)
    }

    private func audioDuration(url: URL) -> TimeInterval {
        // AVAudioFile — синхронно, без deprecated API
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - AudioPlayer (Fix #2: audio session)
// ═══════════════════════════════════════════════════════

class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying  = false
    @Published var currentID: UUID? = nil
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(recording: Recording) {
        if currentID == recording.id {
            isPlaying ? pause() : resume()
            return
        }
        stop()
        do {
            // ✅ Fix #2: playAndRecord + defaultToSpeaker — не конфликтует с recorder
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker]
            )
            try AVAudioSession.sharedInstance().setActive(true)
            // ✅ Fix: принудительно выводим звук в динамик, не в receiver
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)

            player = try AVAudioPlayer(contentsOf: recording.url)
            player?.delegate = self
            player?.play()
            currentID  = recording.id
            duration   = player?.duration ?? 0
            isPlaying  = true
            startTimer()
        } catch {
            print("AudioPlayer error: \(error)")
        }
    }

    func pause()  { player?.pause();  isPlaying = false; stopTimer() }
    func resume() { player?.play();   isPlaying = true;  startTimer() }

    func stop() {
        player?.stop(); player = nil
        isPlaying = false; currentID = nil
        progress = 0; currentTime = 0; duration = 0
        stopTimer()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }

    func seek(to fraction: Double) {
        guard let p = player else { return }
        p.currentTime = fraction * p.duration
        currentTime   = p.currentTime
        progress      = fraction
    }

    func skip(_ sec: TimeInterval) {
        guard let p = player else { return }
        let t     = min(max(p.currentTime + sec, 0), p.duration)
        p.currentTime = t; currentTime = t
        progress  = p.duration > 0 ? t / p.duration : 0
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player else { return }
            self.currentTime = p.currentTime
            self.duration    = p.duration
            self.progress    = p.duration > 0 ? p.currentTime / p.duration : 0
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false; self.progress = 0
            self.currentTime = 0;   self.currentID = nil
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - Root + Notification
// ═══════════════════════════════════════════════════════

extension Notification.Name {
    static let newRecordingSaved = Notification.Name("solarNewRecordingSaved")
}

struct SolarRootView: View {
    @StateObject var store       = RecordingsStore()
    @StateObject var player      = AudioPlayer()
    @StateObject var whisper     = WhisperService()
    @StateObject var translator  = TranslationService()
    @StateObject var summarizer  = SummaryService()
    @State private var tab       = 0

    var body: some View {
        TabView(selection: $tab) {
            SolarRecorderView(store: store, whisper: whisper, summarizer: summarizer)
                .tabItem { Label("Запись", systemImage: "mic.fill") }
                .tag(0)

            RecordingsListView(store: store, player: player, whisper: whisper,
                               translator: translator, summarizer: summarizer)
                .tabItem { Label("Записи", systemImage: "list.bullet") }
                .tag(1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newRecordingSaved)) { _ in
            store.load()
            withAnimation { tab = 1 }
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - RecordingsListView
// ═══════════════════════════════════════════════════════

struct RecordingsListView: View {
    @ObservedObject var store:      RecordingsStore
    @ObservedObject var player:     AudioPlayer
    @ObservedObject var whisper:    WhisperService
    @ObservedObject var translator: TranslationService
    @ObservedObject var summarizer: SummaryService
    @State private var expandedID: UUID? = nil
    @State private var shareURL: URL? = nil
    @State private var searchText = ""

    var filtered: [Recording] {
        guard !searchText.isEmpty else { return store.recordings }
        return store.recordings.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.transcript?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.translation?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.recordings.isEmpty { emptyState } else { recordingsList }
            }
            .searchable(text: $searchText, prompt: "Поиск по записям и тексту...")
            .navigationTitle("Записи")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }

    private var recordingsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { rec in
                    rowView(rec: rec)
                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.leading, 16)
                }
            }
            .padding(.top, 4)
        }
    }

    private func rowView(rec: Recording) -> some View {
        RecordingRow(
            recording:   rec,
            isExpanded:  expandedID == rec.id,
            player:      player,
            whisper:     whisper,
            translator:  translator,
            summarizer:  summarizer,
            store:       store,
            onTap: {
                withAnimation(.spring(response: 0.3)) {
                    expandedID = expandedID == rec.id ? nil : rec.id
                }
            },
            onShare:  { shareURL = rec.url },
            onDelete: {
                if player.currentID == rec.id { player.stop() }
                withAnimation { store.delete(rec) }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.35))
            Text("Нет записей").font(.title3).foregroundColor(.gray)
        }
    }
}

// URL: Identifiable for sheet
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// ═══════════════════════════════════════════════════════
// MARK: - RecordingRow
// ═══════════════════════════════════════════════════════

struct RecordingRow: View {
    let recording:  Recording
    let isExpanded: Bool
    @ObservedObject var player:     AudioPlayer
    @ObservedObject var whisper:    WhisperService
    @ObservedObject var translator: TranslationService
    @ObservedObject var summarizer: SummaryService
    @ObservedObject var store:      RecordingsStore
    let onTap:    () -> Void
    let onShare:  () -> Void
    let onDelete: () -> Void

    @StateObject private var waveform = WaveformData()
    @State private var showDeleteConfirm = false
    @State private var showTranscript    = false
    @State private var showTranslation   = false
    @State private var showSummary       = false
    @State private var showSpeakers      = false

    private var isActive:       Bool { player.currentID == recording.id }
    private var isTranscribing: Bool { whisper.transcribingID == recording.id }
    private var isTranslating:  Bool { translator.translatingIDs.contains(recording.id) }
    private var isSummarizing:  Bool { summarizer.summarizingIDs.contains(recording.id) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header row ──
            Button(action: onTap) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(isActive ? .red : .white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(recording.formattedDate)
                            Text("·")
                            Text(recording.formattedTime)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    }
                    Spacer()
                    if !isExpanded {
                        Text(recording.formattedDuration)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    // Transcript badge
                    if recording.transcript != nil {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.blue.opacity(0.7))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray.opacity(0.4))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(.spring(response: 0.3), value: isExpanded)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)

            // ── Expanded player ──
            if isExpanded {
                VStack(spacing: 14) {

                    // Waveform (✅ Fix #3)
                    WaveformView(
                        samples:  waveform.samples.isEmpty
                                  ? Array(repeating: Float(0.3), count: 80)
                                  : waveform.samples,
                        progress: isActive ? player.progress : 0,
                        color:    isActive ? .red : .white,
                        isLive:   false
                    )
                    .frame(height: 44)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { v in
                                if isActive {
                                    let fraction = min(max(v.location.x / UIScreen.main.bounds.width, 0), 1)
                                    player.seek(to: Double(fraction))
                                }
                            }
                    )
                    .onAppear { waveform.load(from: recording.url) }

                    // Time labels
                    HStack {
                        Text(formatTime(isActive ? player.currentTime : 0))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                        Spacer()
                        Text("-" + formatTime(isActive
                            ? max(0, player.duration - player.currentTime)
                            : recording.duration))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)

                    // Playback controls
                    HStack(spacing: 28) {
                        // Share
                        Button(action: onShare) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 19))
                                .foregroundColor(.white.opacity(0.65))
                        }

                        // Skip -15
                        Button(action: { player.skip(-15) }) {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 25))
                                .foregroundColor(isActive ? .white : .white.opacity(0.4))
                        }
                        .disabled(!isActive)

                        // Play/Pause
                        Button(action: { player.play(recording: recording) }) {
                            ZStack {
                                Circle().fill(Color.red).frame(width: 54, height: 54)
                                Image(systemName: isActive && player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                                    .offset(x: (!isActive || !player.isPlaying) ? 2 : 0)
                            }
                        }

                        // Skip +15
                        Button(action: { player.skip(15) }) {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 25))
                                .foregroundColor(isActive ? .white : .white.opacity(0.4))
                        }
                        .disabled(!isActive)

                        // Delete
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 19))
                                .foregroundColor(.red.opacity(0.65))
                        }
                    }

                    // Transcription + Translation rows
                    VStack(spacing: 8) {
                        // Whisper row
                        HStack(spacing: 10) {
                            if isTranscribing {
                                ProgressView().scaleEffect(0.8).tint(.blue)
                                Text("Распознаю речь...")
                                    .font(.system(size: 12)).foregroundColor(.gray)
                            } else if recording.transcript != nil {
                                Button(action: { showTranscript = true }) {
                                    Label("Показать текст", systemImage: "text.bubble")
                                        .font(.system(size: 12, weight: .medium)).foregroundColor(.blue)
                                }
                            } else {
                                Button(action: { whisper.transcribe(recording: recording, store: store) }) {
                                    Label("Whisper: распознать", systemImage: "waveform.badge.magnifyingglass")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            Spacer()
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 5, height: 5)
                                Text("AI-ready")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.green.opacity(0.8))
                            }
                        }

                        // Translation row (только если есть транскрипция)
                        if recording.transcript != nil {
                            HStack(spacing: 10) {
                                if isTranslating {
                                    ProgressView().scaleEffect(0.8).tint(.orange)
                                    Text("Перевожу...")
                                        .font(.system(size: 12)).foregroundColor(.gray)
                                } else if recording.translation != nil {
                                    Button(action: { showTranslation = true }) {
                                        Label("Показать перевод", systemImage: "globe")
                                            .font(.system(size: 12, weight: .medium)).foregroundColor(.orange)
                                    }
                                } else {
                                    Button(action: {
                                        translator.translate(recording: recording, store: store)
                                    }) {
                                        Label("Перевести на английский", systemImage: "globe")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                                Spacer()
                            }
                        }

                        // Summary row (only if transcript exists)
                        if recording.transcript != nil {
                            HStack(spacing: 10) {
                                if isSummarizing {
                                    ProgressView().scaleEffect(0.8).tint(.purple)
                                    Text("Делаю summary...")
                                        .font(.system(size: 12)).foregroundColor(.gray)
                                } else if recording.summary != nil {
                                    Button(action: { showSummary = true }) {
                                        Label("Показать резюме", systemImage: "sparkles")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.purple)
                                    }
                                } else {
                                    Button(action: {
                                        summarizer.summarize(recording: recording, store: store)
                                    }) {
                                        Label("Сделать summary (GPT)", systemImage: "sparkles")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white.opacity(0.55))
                                    }
                                }
                                Spacer()
                            }
                        }

                        // Speakers row (only if transcript exists)
                        if recording.transcript != nil {
                            HStack(spacing: 10) {
                                Button(action: { showSpeakers = true }) {
                                    Label("Спикеры", systemImage: "person.2")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.cyan.opacity(0.8))
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .confirmationDialog("Удалить запись?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive, action: onDelete)
            Button("Отменить", role: .cancel) {}
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(recording: recording)
        }
        .sheet(isPresented: $showTranslation) {
            TranslationSheet(recording: recording)
        }
        .sheet(isPresented: $showSummary) {
            SummarySheet(recording: recording)
        }
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet(recording: recording)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t)/60; let s = Int(t)%60
        return String(format: "%d:%02d", m, s)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - TranscriptSheet
// ═══════════════════════════════════════════════════════

struct TranscriptSheet: View {
    let recording: Recording
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(recording.name)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                        if let summary = recording.summary {
                            Text("Резюме")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.blue)
                            Text(summary)
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.9))
                            Divider().background(Color.white.opacity(0.1))
                        }
                        if let transcript = recording.transcript {
                            Text("Транскрипция")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.blue)
                            Text(transcript)
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Текст записи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if let t = recording.transcript {
                        ShareLink(item: t) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .foregroundColor(.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}


// ═══════════════════════════════════════════════════════
// MARK: - SummarySheet
// ═══════════════════════════════════════════════════════

struct SummarySheet: View {
    let recording: Recording
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Meta
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12))
                                .foregroundColor(.purple)
                            Text("AI Summary · gpt-4o-mini")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.gray)
                        }

                        if let summary = recording.summary {
                            Text(summary)
                                .font(.system(size: 15)).lineSpacing(4)
                                .foregroundColor(.white.opacity(0.88))
                                .textSelection(.enabled)
                        }

                        if let transcript = recording.transcript {
                            Divider().background(Color.white.opacity(0.1))
                            Text("Источник")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.gray)
                            Text(transcript)
                                .font(.system(size: 13))
                                .foregroundColor(.gray.opacity(0.7))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Резюме")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let s = recording.summary {
                        ShareLink(item: s) {
                            Image(systemName: "square.and.arrow.up")
                        }.foregroundColor(.white)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }.foregroundColor(.red)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - SolarRecorderView (with live waveform)
// ═══════════════════════════════════════════════════════

struct SolarRecorderView: View {
    @ObservedObject var store:     RecordingsStore
    @ObservedObject var whisper:   WhisperService
    @ObservedObject var summarizer: SummaryService
    @StateObject private var recorder = SolarRecorder()
    @StateObject private var liveWaveform = WaveformData()
    @State private var vadEnabled = false
    @State private var autoTranscribe = true
    @State private var autoSummary    = false
    @State private var profile: RecordingProfile = .standard
    @State private var showSaved = false
    @State private var savedName = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 4) {
                    Text("Solar Record")
                        .font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                    Text("v3 · waveform · Whisper · AI-ready")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.gray)
                }
                .padding(.top, 52)

                Spacer()

                // Timer
                Text(formatDuration(recorder.duration))
                    .font(.system(size: 52, weight: .thin, design: .monospaced))
                    .foregroundColor(recorder.isRecording ? .red : .white)

                Spacer().frame(height: 20)

                // Live waveform
                WaveformView(
                    samples:  liveWaveform.samples.isEmpty
                              ? Array(repeating: Float(0.05), count: 60)
                              : liveWaveform.samples,
                    progress: 1.0,
                    color:    recorder.isRecording ? .red : .white,
                    isLive:   true
                )
                .frame(height: 48)
                .padding(.horizontal, 24)
                .animation(.none, value: liveWaveform.samples.count)

                Spacer().frame(height: 10)

                // VAD indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(recorder.isRecording
                              ? (recorder.isSpeaking ? Color.green : Color.gray.opacity(0.3))
                              : Color.gray.opacity(0.2))
                        .frame(width: 6, height: 6)
                    Text(recorder.isRecording
                         ? (recorder.isSpeaking ? "речь" : "тишина")
                         : "Готов · measurement · no AGC")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(recorder.isRecording && recorder.isSpeaking ? .green : .gray)
                }

                Spacer()

                // Profile picker
                if !recorder.isRecording {
                    Picker("", selection: $profile) {
                        ForEach(RecordingProfile.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 40)
                    .colorScheme(.dark)
                    Spacer().frame(height: 16)
                }

                // VAD Toggle
                VStack(spacing: 10) {
                    Toggle(isOn: $vadEnabled) {
                        Label("Авто-стоп по тишине (VAD)", systemImage: "waveform.badge.mic")
                            .font(.system(size: 13)).foregroundColor(.gray)
                    }
                    .tint(.red).disabled(recorder.isRecording)
                    Toggle(isOn: $autoTranscribe) {
                        Label("Авто-транскрипция (Whisper)", systemImage: "waveform.badge.magnifyingglass")
                            .font(.system(size: 13)).foregroundColor(.gray)
                    }
                    .tint(.blue).disabled(recorder.isRecording)
                    Toggle(isOn: $autoSummary) {
                        Label("Авто-резюме (GPT)", systemImage: "sparkles")
                            .font(.system(size: 13)).foregroundColor(.gray)
                    }
                    .tint(.purple).disabled(recorder.isRecording || !autoTranscribe)
                }
                .padding(.horizontal, 40)

                Spacer()

                // Record button
                Button(action: toggleRecording) {
                    ZStack {
                        Circle()
                            .strokeBorder(recorder.isRecording ? Color.red : Color.white, lineWidth: 3)
                            .frame(width: 80, height: 80)
                        if recorder.isRecording {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red).frame(width: 28, height: 28)
                        } else {
                            Circle().fill(Color.red).frame(width: 60, height: 60)
                        }
                    }
                }
                .padding(.bottom, 20)

                // Saved banner
                if showSaved {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text(savedName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.green).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                }
                if let err = recorder.errorMessage {
                    Text(err).font(.caption).foregroundColor(.red).padding(.horizontal)
                }

                Spacer()

                // Badges
                HStack(spacing: 6) {
                    ForEach(["AudioFileID", "measurement", "VAD", "waveform"], id: \.self) { t in
                        Text(t).font(.system(size: 10, weight: .medium)).foregroundColor(.gray)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
                    }
                }
                .padding(.bottom, 30)
            }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            liveWaveform.reset()
            if let result = recorder.stopRecording() {
                NotificationCenter.default.post(name: .newRecordingSaved, object: nil)
                savedName = result.wav.lastPathComponent
                withAnimation { showSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showSaved = false }
                }
                // ✅ Авто-транскрипция
                if autoTranscribe {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if let rec = store.recordings.first(where: { $0.url == result.wav }) {
                            
                            whisper.transcribe(recording: rec, store: store)

                            // ✅ Авто-резюме после транскрипции
                            if autoSummary {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                    if let updated = store.recordings.first(where: { $0.url == result.wav }),
                                       updated.transcript != nil {
                                        summarizer.summarize(recording: updated, store: store)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            showSaved = false
            liveWaveform.reset()
            recorder.startRecording(
                vad: vadEnabled,
                profile: profile,
                onBuffer: { [weak liveWaveform] buf in liveWaveform?.append(buffer: buf) }
            )
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t)/60; let s = Int(t)%60
        let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%01d", m, s, ms)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - TranslationSheet
// ═══════════════════════════════════════════════════════

struct TranslationSheet: View {
    let recording: Recording
    @Environment(\.dismiss) var dismiss
    @StateObject private var tts = SolarTTSManager()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Text(recording.formattedDate)
                            Text("·")
                            Text(recording.formattedTime)
                            Text("·")
                            Text(recording.formattedDuration)
                        }
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(.gray)

                        if let translation = recording.translation {
                            Label("Перевод (English)", systemImage: "globe")
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.orange)
                            Text(translation)
                                .font(.system(size: 15)).lineSpacing(4)
                                .foregroundColor(.white.opacity(0.88))
                                .textSelection(.enabled)
                            TTSSpeakButton(text: translation,
                                           language: "en",
                                           tts: tts)
                        }

                        if let transcript = recording.transcript {
                            Divider().background(Color.white.opacity(0.1))
                            Label("Оригинал", systemImage: "text.quote")
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.gray)
                            Text(transcript)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.5))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Перевод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if let t = recording.translation {
                        ShareLink(item: t) {
                            Image(systemName: "square.and.arrow.up")
                        }.foregroundColor(.white)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }.foregroundColor(.red)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - ShareSheet
// ═══════════════════════════════════════════════════════

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}


