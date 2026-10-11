import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognizer (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26). Nothing
/// leaves the Mac; a language's model downloads once from Apple, managed by the system.
enum AppleSpeech {
    static func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
    static func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }

    /// Whether this Mac can do on-device speech recognition for `localeID` at all. Virtual Macs (CI
    /// runners) report `unsupported`: there's no model to download, so voice input can't work there.
    static func isSupported(localeID: String) async -> Bool {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: localeID), preset: .transcription)
        return await AssetInventory.status(forModules: [transcriber]) != .unsupported
    }

    /// Make sure the recognizer for `locale` is on this Mac. Nothing to do when the system already has
    /// it (usually true for the Mac's own language); otherwise it downloads once. The installation
    /// request reserves the locale itself (checked on a real Mac), so no separate reserve step.
    static func installIfNeeded(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            // Otherwise the download fails with a misleading "not subscribed to transcription.en".
            let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            throw VoiceInputError("This Mac doesn't support on-device speech recognition for \(language).")
        default:
            break
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw VoiceInputError("Couldn't download \(locale.identifier) speech recognition: \(error.localizedDescription)")
        }
    }

    /// Transcribe a whole audio file. Used by the tests, which feed it speech macOS generates.
    static func transcribe(file: URL, localeID: String) async throws -> String {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installIfNeeded(transcriber, locale: locale)
        let audio = try AVAudioFile(forReading: file)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A live Apple transcription fed from the microphone. `onText` gets everything heard so far: the
/// finalized text plus the still-changing tail, so the message box updates as you speak.
final class AppleLiveTranscription: AudioSink, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let stream: AsyncStream<AnalyzerInput>
    let format: AVAudioFormat
    private var results: Task<String, Error>?

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    }

    static func make(localeID: String) async throws -> AppleLiveTranscription {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await AppleSpeech.installIfNeeded(transcriber, locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceInputError("This Mac's speech recognizer isn't ready. Try again in a moment.")
        }
        return AppleLiveTranscription(transcriber: transcriber, analyzer: SpeechAnalyzer(modules: [transcriber]),
                                      format: format)
    }

    func start(onText: @escaping @Sendable (String) -> Void) async throws {
        let transcriber = self.transcriber
        results = Task {
            var finalized = ""
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                if result.isFinal {
                    finalized += piece
                    onText(finalized)
                } else {
                    onText(finalized + piece)
                }
            }
            return finalized
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Feed a buffer already converted to `format`.
    func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Stop listening and return the final text.
    func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func cancel() {
        input.finish()
        results?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}
