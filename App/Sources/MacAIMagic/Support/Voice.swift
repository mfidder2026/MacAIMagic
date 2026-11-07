import Foundation
import AVFoundation
import Speech

/// Speech on this Mac (phase 6): speaking a question in the chat, reading answers aloud, and turning a Telegram voice
/// message into text. Recognition runs on the Mac (macOS's own speech recognition, on-device where the language has
/// it); nothing goes to the internet for it.
@MainActor
final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Voice()

    @Published private(set) var listening = false
    /// What was heard so far (while listening).
    @Published private(set) var heard = ""
    @Published private(set) var speaking: UUID?
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// The app's language as a speech locale.
    static var locale: Locale {
        switch AppLanguage.current {
        case .nl: return Locale(identifier: "nl-NL")
        case .de: return Locale(identifier: "de-DE")
        case .fr: return Locale(identifier: "fr-FR")
        default: return Locale(identifier: "en-US")
        }
    }

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        }
    }

    // MARK: - speaking a question

    /// Starts listening; every partial result goes to `onText`. Stop with `stopListening`.
    func startListening(onText: @escaping (String) -> Void) async {
        problem = nil
        guard await Self.authorize() else {
            problem = L("Spraakherkenning is niet toegestaan. Zet MacAIMagic aan in Systeeminstellingen → Privacy en beveiliging → Spraakherkenning.")
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = L("De microfoon is niet toegestaan. Zet MacAIMagic aan in Systeeminstellingen → Privacy en beveiliging → Microfoon.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale), recognizer.isAvailable else {
            problem = L("Spraakherkenning is er niet voor deze taal op deze Mac.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            problem = L("De microfoon start niet: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }
        heard = ""
        listening = true
        recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.heard = text; onText(text) }
                if final { self.stopListening() }
            }
        }
    }

    func stopListening() {
        guard listening else { return }
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        recognition?.finish()
        recognition = nil
    }

    // MARK: - a recording (a Telegram voice message)

    /// The text of an audio file (Ogg/Opus from Telegram, m4a, wav …); nil with the reason when it fails.
    static func transcribe(_ file: URL, locale given: Locale? = nil) async -> (text: String?, error: String?) {
        let locale = given ?? Voice.locale
        guard await authorize() else { return (nil, L("Spraakherkenning is niet toegestaan op de Mac.")) }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return (nil, L("Spraakherkenning is er niet voor deze taal op deze Mac."))
        }
        let req = SFSpeechURLRecognitionRequest(url: file)
        req.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        return await withCheckedContinuation { c in
            var done = false
            recognizer.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal { done = true; c.resume(returning: (result.bestTranscription.formattedString, nil)) }
                else if let error { done = true; c.resume(returning: (nil, error.localizedDescription)) }
            }
        }
    }

    // MARK: - reading aloud

    /// Markdown to plain sentences: no code blocks, links as their text, no symbols read out.
    nonisolated static func speakable(_ markdown: String) -> String {
        var parts: [String] = []
        for (i, part) in markdown.components(separatedBy: "```").enumerated() where i % 2 == 0 { parts.append(part) }
        var s = parts.joined(separator: " ")
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*\|?[-: |]+\|?\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`#>|]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String, id: UUID) {
        if speaking == id { stopSpeaking(); return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: Self.speakable(text))
        let chosen = Settings.shared.voiceID
        u.voice = (chosen.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: chosen)) ?? AVSpeechSynthesisVoice(language: Self.locale.identifier)
        speaking = id
        synth.speak(u)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
        speaking = nil
    }

    /// The voices of the app's language, best first, for the settings.
    static var voices: [AVSpeechSynthesisVoice] {
        let lang = String(locale.identifier.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.speaking = nil } }
    }
}
