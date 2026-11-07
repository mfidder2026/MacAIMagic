import Foundation
import AVFoundation
import Speech

/// Speech to text with SpeechAnalyzer (macOS 26 and later): Apple's newer on-device model, which needs no Siri or
/// Dictation switched on. The language model is downloaded once by macOS (AssetInventory). Voice falls back to
/// SFSpeechRecognizer where this is not there.
@available(macOS 26, *)
final class ModernSpeech: @unchecked Sendable {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private let engine = AVAudioEngine()

    /// The transcriber for this language, with its model installed; nil when the language is not there.
    static func transcriber(for locale: Locale, live: Bool) async throws -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let t = SpeechTranscriber(locale: supported, preset: live ? .progressiveTranscription : .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
        return t
    }

    /// Listens to the microphone; `onText` gets the whole text so far (final parts plus the part still changing).
    /// False when this language has no SpeechTranscriber here (then the caller uses the older recognizer).
    func start(locale: Locale, onText: @escaping @Sendable (String) -> Void, onError: @escaping @Sendable (String) -> Void) async throws -> Bool {
        guard let transcriber = try await Self.transcriber(for: locale, live: true) else { return false }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let mic = engine.inputNode.outputFormat(forBus: 0)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: mic) else { return false }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        input = continuation
        results = Task {
            var final = ""
            do {
                for try await r in transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal {
                        final += text
                        onText(final)
                    } else {
                        onText(final + text)
                    }
                }
            } catch {
                onError(error.localizedDescription)
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        let converter = mic == format ? nil : AVAudioConverter(from: mic, to: format)
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: mic) { buffer, _ in
            guard let converter else { continuation.yield(AnalyzerInput(buffer: buffer)); return }
            let ratio = format.sampleRate / mic.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil && out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
        return true
    }

    func stop() async {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        // the last results come in after the end of the input
        try? await Task.sleep(for: .milliseconds(300))
        results?.cancel()
        results = nil
    }

    /// The text of a recording (a Telegram voice message); nil when the language is not there.
    static func transcribe(_ file: URL, locale: Locale) async throws -> String? {
        guard let transcriber = try await transcriber(for: locale, live: false) else { return nil }
        let audio = try AVAudioFile(forReading: file)
        let collect = Task {
            var text = ""
            for try await r in transcriber.results where r.isFinal { text += String(r.text.characters) }
            return text
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: audio, modules: [transcriber], finishAfterFile: true)
        _ = analyzer
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
