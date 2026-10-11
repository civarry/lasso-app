import AVFoundation
import Foundation
import Observation

/// Chat voice input: click the mic and talk instead of typing. English, on this Mac, using Apple's
/// built-in speech recognition, so it depends on no model or connection and nothing leaves the Mac.
/// Words appear in the message box as you speak; it stops by itself when you pause; the text is left
/// for you to edit and send. It never sends itself.
@MainActor
@Observable
final class VoiceInputController {
    static let shared = VoiceInputController()

    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle

    private var engine: AVAudioEngine?
    private var live: AppleLiveTranscription?
    private var baseText = ""
    private var clearFailure: Task<Void, Never>?
    private var silenceWatch: Task<Void, Never>?
    /// Bumped whenever a dictation ends, so a recognizer update that arrives late (after Send, Esc or
    /// stop) can't write into the message box. Before this, sent text reappeared in the box.
    private(set) var session = 0

    var isActive: Bool {
        switch state {
        case .starting, .listening, .finishing: true
        default: false
        }
    }

    func toggle() {
        switch state {
        case .listening: Task { await stop() }
        case .idle, .failed: Task { await start() }
        case .starting, .finishing: break
        }
    }

    // MARK: Start / stop

    func start() async {
        guard !isActive else { return }
        clearFailure?.cancel()
        state = .starting
        guard await Self.microphoneAllowed() else {
            fail("Microphone access is off for Lasso. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }
        baseText = ChatController.shared.input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let live = try await AppleLiveTranscription.make(localeID: await Self.englishLocaleID())
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceInputError("No microphone is available.")
            }
            let activity = SpeechActivity()
            Self.installTap(on: input, format: format, sink: live, activity: activity)
            self.live = live
            let session = self.session
            try await live.start { text in
                Task { @MainActor in VoiceInputController.shared.show(text, session: session) }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            state = .listening
            watchForSilence(activity)
        } catch {
            teardown()
            fail(error.localizedDescription)
        }
    }

    /// Stop listening; the final text replaces the live draft in the box.
    func stop() async {
        guard state == .listening else { return }
        silenceWatch?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let live = self.live
        self.live = nil
        state = .finishing
        do {
            let text = try await Self.finish(live)
            show(text, session: session)
            session += 1
            state = .idle
        } catch {
            session += 1
            fail(error.localizedDescription)
        }
    }

    /// Stop without keeping anything: the message box goes back to what it was.
    func cancel() {
        guard isActive else { return }
        live?.cancel()
        teardown()
        ChatController.shared.input = baseText
        state = .idle
    }

    /// Send what's in the box, finishing any dictation first so its last words are included and
    /// nothing the recognizer says afterwards reaches the box.
    func sendEndingDictation() async {
        switch state {
        case .listening: await stop()
        case .starting: cancel()
        case .finishing: return          // a stop is already finishing; it will fill the box
        case .idle, .failed: break
        }
        if case .failed = state { return }
        ChatController.shared.send()
    }

    /// End a live transcription and return its text. Runs in its own task: a caller that has been
    /// cancelled (the silence watcher, which the stop cancels) must not cancel the finish with it.
    static func finish(_ live: AppleLiveTranscription?) async throws -> String {
        guard let live else { return "" }
        return try await Task { try await live.finish() }.value
    }

    // MARK: Helpers

    /// Write what was heard into the box, but only for the dictation that's still running.
    func show(_ transcript: String, session: Int) {
        guard session == self.session else { return }
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        ChatController.shared.input = [baseText, heard].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func teardown() {
        session += 1
        silenceWatch?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        live = nil
    }

    private func fail(_ message: String) {
        state = .failed(message)
        clearFailure?.cancel()
        clearFailure = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if case .failed = self?.state { self?.state = .idle }
        }
    }

    /// Stop by itself once you've stopped talking, like system dictation. The stop runs in a task of
    /// its own, not inside this watcher, which the stop cancels.
    private func watchForSilence(_ activity: SpeechActivity) {
        silenceWatch?.cancel()
        let started = Date()
        silenceWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .listening else { return }
                switch activity.decision(now: Date(), startedAt: started) {
                case .keepListening:
                    continue
                case .stop:
                    Task { await self.stop() }
                    return
                case .nothingHeard:
                    self.cancel()
                    self.fail("Didn't hear anything.")
                    return
                }
            }
        }
    }

    /// English, in the Mac's own region when Apple has it (en_GB, en_AU…), else US English.
    static func englishLocaleID() async -> String {
        let english = await AppleSpeech.supportedLocales().filter { $0.language.languageCode?.identifier == "en" }
        if let local = english.first(where: { $0.region == Locale.current.region }) { return local.identifier }
        if let us = english.first(where: { $0.region?.identifier == "US" }) { return us.identifier }
        return english.first?.identifier ?? "en_US"
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Microphone tap

    /// The block goes in by name, never as an inline closure: a closure written inline in this
    /// @MainActor code, straight into `installTap`, gets a main-thread check that traps on the audio
    /// thread (the crash reported 2026-09-28). `MicrophoneTapTests` calls this exact function.
    static func installTap(on node: AVAudioNode, format: AVAudioFormat, sink: any AudioSink,
                           activity: SpeechActivity? = nil) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format,
                        block: tap(converter: BufferConverter(from: format, to: sink.format), sink: sink,
                                   activity: activity))
    }

    nonisolated static func tap(converter: BufferConverter?, sink: any AudioSink,
                                activity: SpeechActivity?) -> AVAudioNodeTapBlock {
        { buffer, _ in
            activity?.note(level: SpeechActivity.level(of: buffer), at: Date())
            if let converted = converter?.convert(buffer) { sink.feed(converted) }
        }
    }
}

struct VoiceInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Where microphone audio goes, in the format it wants. Fed from the audio thread.
protocol AudioSink: AnyObject, Sendable {
    var format: AVAudioFormat { get }
    func feed(_ buffer: AVAudioPCMBuffer)
}

/// Converts microphone buffers to the format the recognizer wants (sample rate, channels, sample
/// type). Follows the format the buffers actually arrive in: the one read before the engine starts can
/// differ (an engine reported 44.1 kHz and delivered 48 kHz; Bluetooth headsets switch rates when the
/// mic opens), and a converter built for the wrong input rejects every buffer. Audio thread only.
final class BufferConverter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private let output: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        self.output = output
        converter = AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// Tells speech from silence by loudness, so dictation can end itself. Written from the audio thread,
/// read from the main actor.
final class SpeechActivity: @unchecked Sendable {
    enum Decision: Equatable { case keepListening, stop, nothingHeard }

    /// RMS above this is speech (about -34 dBFS). Room noise and a quiet fan sit well below it.
    static let speechLevel: Float = 0.02
    /// Stop this long after the last speech.
    static let silenceAfterSpeech: TimeInterval = 2.0
    /// Give up if nothing is said for this long after starting.
    static let noSpeechTimeout: TimeInterval = 8.0

    private let lock = NSLock()
    private var lastSpeech: Date?

    func note(level: Float, at time: Date) {
        guard level >= Self.speechLevel else { return }
        lock.lock(); lastSpeech = time; lock.unlock()
    }

    func decision(now: Date, startedAt: Date) -> Decision {
        lock.lock(); let last = lastSpeech; lock.unlock()
        guard let last else {
            return now.timeIntervalSince(startedAt) >= Self.noSpeechTimeout ? .nothingHeard : .keepListening
        }
        return now.timeIntervalSince(last) >= Self.silenceAfterSpeech ? .stop : .keepListening
    }

    /// RMS of the first channel, for float or 16-bit buffers.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let f = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s[i]) / 32768; sum += v * v }
        } else {
            return 0
        }
        return (sum / Float(n)).squareRoot()
    }
}
