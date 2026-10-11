import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognizer (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26). Nothing
/// leaves the Mac; a language's model downloads once from Apple, managed by the system.
enum AppleSpeech {
    static func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
    static func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }

    /// Make sure the recognizer for `locale` is on this Mac. Nothing to do when the system already has
    /// it (usually true for the Mac's own language). Otherwise the app has to *reserve* the locale
    /// before asking for the download: without it the request fails with "<app> is not subscribed to
    /// transcription.<lang>", which is what a fresh Mac (CI) hit on the first tap of the mic.
    static func installIfNeeded(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return }
        // Each step names itself in the error, so a failure says where it happened (the API's own
        // messages don't), e.g. "reserve en_US (status supported): …".
        var reserved = false
        do {
            reserved = try await AssetInventory.reserve(locale: locale)
        } catch {
            throw VoiceInputError("Couldn't reserve \(locale.identifier) speech (status \(status)): \(error.localizedDescription)")
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw VoiceInputError("Couldn't download \(locale.identifier) speech (status \(status), reserved \(reserved)): "
                                  + error.localizedDescription)
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
