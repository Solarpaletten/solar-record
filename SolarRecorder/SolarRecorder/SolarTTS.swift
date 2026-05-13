// SolarRecorder/SolarRecorder/SolarTTS.swift
// Изолированный TTS-модуль. Не изменяет стабильную базу.
// Подключается только через @StateObject в TranslationSheet.

import Foundation
import AVFoundation
import SwiftUI
import Combine

// ═══════════════════════════════════════════════════════
// MARK: - SolarTTSManager
// ═══════════════════════════════════════════════════════

final class SolarTTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    @Published var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    func speak(text: String, language: String? = nil) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolveVoice(language: language)
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        configureAudioSession()
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                            didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    // MARK: - Private

    private func resolveVoice(language: String?) -> AVSpeechSynthesisVoice? {
        // Если язык передан явно — используем его
        if let lang = language {
            let normalized = normalizeLanguageCode(lang)
            if let voice = AVSpeechSynthesisVoice(language: normalized) {
                return voice
            }
        }
        // Фолбэк: системный язык устройства
        return AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en")
    }

    private func normalizeLanguageCode(_ lang: String) -> String {
        // Приводим к BCP-47 который принимает AVSpeechSynthesisVoice
        switch lang.lowercased() {
        case "ru", "russian":   return "ru-RU"
        case "en", "english",
             "en-us", "en-gb":  return "en-US"
        case "de", "german":    return "de-DE"
        case "fr", "french":    return "fr-FR"
        case "es", "spanish":   return "es-ES"
        case "pl", "polish":    return "pl-PL"
        case "uk", "ukrainian": return "uk-UA"
        case "zh", "chinese":   return "zh-CN"
        default:                return lang
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - TTSSpeakButton  (переиспользуемый UI-компонент)
// ═══════════════════════════════════════════════════════

struct TTSSpeakButton: View {
    let text: String
    let language: String?
    @ObservedObject var tts: SolarTTSManager

    var body: some View {
        Button {
            if tts.isSpeaking { tts.stop() }
            else              { tts.speak(text: text, language: language) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tts.isSpeaking ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                Text(tts.isSpeaking ? "Стоп" : "Озвучить")
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(tts.isSpeaking ? .red : .orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill((tts.isSpeaking ? Color.red : Color.orange).opacity(0.15))
            )
        }
    }
}
