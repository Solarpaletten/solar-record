// SolarRecorder/SolarRecorder/SolarRecorder_v3.2.swift


import Foundation
import AVFoundation
import UIKit
import CryptoKit
import Combine

// MARK: - SolarRecorder v3.2
// Ключевое изменение: пишем WAV через FileHandle напрямую
// Никакого Apple audio container API → никакого FLLR/JUNK padding
// fmt at byte 12, data at byte 44 — гарантировано

public class SolarRecorder: NSObject, ObservableObject {

    @Published public var isRecording: Bool = false
    @Published public var duration: TimeInterval = 0
    @Published public var lastFileURL: URL? = nil
    @Published public var lastMetaURL: URL? = nil
    @Published public var lastSHA256: String? = nil
    @Published public var errorMessage: String? = nil
    @Published public var isSpeaking: Bool = false

    // Settings
    private let sampleRate: Double   = 16000
    private let channelCount: Int    = 1
    private let bitDepth: Int        = 16

    // VAD
    private let vadSilenceThreshold: Float      = 0.01
    private let vadSilenceMaxDuration: TimeInterval = 8.0

    // Private
    private var audioEngine: AVAudioEngine?
    private var fileHandle: FileHandle?          // ← raw FileHandle, не AudioFileID
    private var outputURL: URL?
    private var totalBytesWritten: Int64 = 0
    private var timer: Timer?
    private var startTime: Date?
    private var lastSpeechTime: Date?
    private var vadEnabled: Bool = false
    private var profile: RecordingProfile = .standard
    private var onBufferCallback: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Start

    @discardableResult
    public func startRecording(
        vad: Bool = false,
        profile: RecordingProfile = .standard,
        onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil
    ) -> URL? {
        guard !isRecording else { return nil }
        errorMessage = nil
        vadEnabled = vad
        self.profile = profile
        onBufferCallback = onBuffer

        do {
            try configureAudioSession()
            let url = makeOutputURL(profile: profile)
            try openRawFile(url: url)
            try startEngine()
            outputURL = url
            lastFileURL = nil; lastMetaURL = nil; lastSHA256 = nil
            startTime = Date(); lastSpeechTime = Date()
            totalBytesWritten = 0
            startTimer()
            isRecording = true
            return url
        } catch {
            errorMessage = error.localizedDescription
            cleanup()
            return nil
        }
    }

    @discardableResult
    public func stopRecording() -> (wav: URL, meta: URL, sha256: String)? {
        guard isRecording else { return nil }
        let dur = duration
        stopEngine()
        finalizeWavFile()     // ← записываем корректный header с правильным data size
        stopTimer()
        isRecording = false; isSpeaking = false; onBufferCallback = nil

        guard let url = outputURL else { return nil }
        lastFileURL = url
        let sha  = computeSHA256(fileURL: url)
        lastSHA256 = sha
        if let hash = sha { writeSHA256File(wavURL: url, hash: hash) }
        let meta = writeMetadata(wavURL: url, duration: dur, sha256: sha)
        lastMetaURL = meta
        outputURL = nil
        return (url, meta, sha ?? "")
    }

    // MARK: - Audio Session

    private func configureAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .measurement,
                          options: [.defaultToSpeaker ])
        try s.setPreferredSampleRate(sampleRate)
        try s.setPreferredIOBufferDuration(0.02)
        try s.setActive(true)
    }

    // MARK: - Raw FileHandle WAV (zero padding guaranteed)

    private func openRawFile(url: URL) throws {
        // Создаём файл
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: url.path) else {
            throw SolarError.fileHandleError
        }
        fileHandle = fh
        // Пишем placeholder header (44 байта)
        // Будет перезаписан в finalizeWavFile() с правильным data size
        fh.write(makeWavHeader(dataSize: 0))
    }

    private func writeRawPCM(buffer: AVAudioPCMBuffer) {
        guard let fh = fileHandle,
              let int16Data = buffer.int16ChannelData else { return }
        let frameCount  = Int(buffer.frameLength)
        let byteCount   = frameCount * channelCount * (bitDepth / 8)
        let data        = Data(bytes: int16Data[0], count: byteCount)
        fh.write(data)
        totalBytesWritten += Int64(byteCount)
    }

    private func finalizeWavFile() {
        guard let fh = fileHandle else { return }
        // Перематываем в начало и пишем корректный header
        fh.seek(toFileOffset: 0)
        fh.write(makeWavHeader(dataSize: Int(totalBytesWritten)))
        fh.closeFile()
        fileHandle = nil
    }

    // MARK: - WAV Header (44 bytes, no padding, data at byte 44)

    private func makeWavHeader(dataSize: Int) -> Data {
        var h = Data()
        func u32(_ v: UInt32) { h.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        func u16(_ v: UInt16) { h.append(contentsOf: withUnsafeBytes(of: v.littleEndian, Array.init)) }
        func str(_ s: String) { h.append(contentsOf: s.utf8) }

        let byteRate  = sampleRate * Double(channelCount * bitDepth / 8)
        let blockAlign = channelCount * bitDepth / 8

        str("RIFF");  u32(UInt32(dataSize + 36))      // ChunkSize
        str("WAVE")
        str("fmt ");  u32(16)                          // Subchunk1Size = 16 (PCM)
        u16(1)                                         // AudioFormat = 1 (PCM)
        u16(UInt16(channelCount))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitDepth))
        str("data");  u32(UInt32(dataSize))            // Subchunk2Size

        // assert: h.count == 44
        return h
    }

    // MARK: - Engine

    private func startEngine() throws {
        let engine    = AVAudioEngine()
        let input     = engine.inputNode
        let nativeFmt = input.outputFormat(forBus: 0)

        guard let int16Fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate, channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else { throw SolarError.formatError }

        guard let floatFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else { throw SolarError.formatError }

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFmt) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Float for VAD + waveform
            if let floatBuf = self.convert(buffer: buffer, from: nativeFmt, to: floatFmt) {
                let rms      = self.computeRMS(buffer: floatBuf)
                let speaking = rms > self.vadSilenceThreshold
                DispatchQueue.main.async { self.isSpeaking = speaking }
                if speaking { self.lastSpeechTime = Date() }
                self.onBufferCallback?(floatBuf)
            }

            // VAD auto-stop
            if self.vadEnabled,
               let last = self.lastSpeechTime,
               Date().timeIntervalSince(last) > self.vadSilenceMaxDuration {
                DispatchQueue.main.async { self.stopRecording() }
                return
            }

            // Int16 → write raw
            if let int16Buf = self.convert(buffer: buffer, from: nativeFmt, to: int16Fmt) {
                self.writeRawPCM(buffer: int16Buf)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    private func stopEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - VAD

    private func computeRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength); guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return sqrt(sum / Float(n))
    }

    // MARK: - Format Conversion

    private func convert(buffer: AVAudioPCMBuffer, from src: AVAudioFormat, to dst: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let conv = AVAudioConverter(from: src, to: dst) else { return nil }
        let ratio     = dst.sampleRate / src.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outFrames) else { return nil }
        var consumed  = false; var err: NSError?
        let status    = conv.convert(to: out, error: &err) { _, s in
            if consumed { s.pointee = .noDataNow; return nil }
            s.pointee = .haveData; consumed = true; return buffer
        }
        return (status == .error || err != nil) ? nil : out
    }

    // MARK: - SHA256

    func computeSHA256(fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeSHA256File(wavURL: URL, hash: String) {
        let url = wavURL.deletingPathExtension().appendingPathExtension("sha256")
        try? hash.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Metadata

    @discardableResult
    private func writeMetadata(wavURL: URL, duration: TimeInterval, sha256: String?) -> URL {
        let meta: [String: Any] = [
            "source":           "solar_record_v3.2",
            "device":           "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
            "sample_rate":      Int(sampleRate),
            "channels":         channelCount,
            "bit_depth":        bitDepth,
            "format":           "WAV PCM",
            "wav_writer":       "FileHandle raw (no FLLR/JUNK, data at byte 44)",
            "audio_source":     "measurement_mode",
            "compression":      "none",
            "profile":          profile.rawValue,
            "created_at":       ISO8601DateFormatter().string(from: startTime ?? Date()),
            "duration_seconds": String(format: "%.2f", duration),
            "file":             wavURL.lastPathComponent,
            "sha256":           sha256 ?? "",
            "ai_ready":         true
        ]
        let url = wavURL.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
            try? data.write(to: url)
        }
        return url
    }

    // MARK: - Helpers

    private func makeOutputURL(profile: RecordingProfile) -> URL {
        let docs   = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("SolarRecords", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return folder.appendingPathComponent("solar_\(f.string(from: Date()))_ios_\(profile.rawValue).wav")
    }

    private func cleanup() {
        fileHandle?.closeFile(); fileHandle = nil
        stopEngine(); stopTimer()
    }

    private func startTimer() {
        duration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let s = self.startTime else { return }
            self.duration = Date().timeIntervalSince(s)
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
}

// MARK: - Profile

public enum RecordingProfile: String, CaseIterable {
    case standard = "standard"
    case legal    = "legal"
    case erpNote  = "erp_note"

    var displayName: String {
        switch self {
        case .standard: return "Стандарт"
        case .legal:    return "Юридический"
        case .erpNote:  return "ERP"
        }
    }
}

// MARK: - Errors

public enum SolarError: Error, LocalizedError {
    case formatError
    case fileHandleError
    public var errorDescription: String? {
        switch self {
        case .formatError:     return "WAV format error"
        case .fileHandleError: return "Cannot open file for writing"
        }
    }
}
