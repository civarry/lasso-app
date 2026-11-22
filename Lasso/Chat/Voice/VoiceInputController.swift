import AVFoundation
import Foundation
import Observation

/// Chat voice input: click the mic and talk instead of typing. English, on this Mac, using Apple's
/// built-in speech recognition, so it depends on no model or connection and nothing leaves the Mac.
/// Words appear in the message box as you speak; it stops by itself when you've finished (see
/// `SpeechActivity`); the text is left
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
    private var clearFailure: Task<Void, Never>?
    private var silenceWatch: Task<Void, Never>?
    private var activity: SpeechActivity?
    /// Bumped whenever a dictation ends, so a recognizer update that arrives late (after Send, Esc or
    /// stop) can't write into the message box. Before this, sent text reappeared in the box.
    private(set) var session = 0

    // The dictation's place in the box. Words go in at the caret (replacing a selection, like system
    // dictation), not at the end, and text typed before or after them is left alone.

    /// Where the dictation's words sit in the box, in UTF-16 units, including `lead` and `trail`.
    private(set) var span = NSRange(location: 0, length: 0)
    /// A space added before the words when the caret was right after a word, and after them when it
    /// was right before one.
    private var lead = ""
    private var trail = ""
    /// What the dictation replaced (a selection), put back on Esc.
    private var replaced = ""
    /// The person edited inside the span, so it no longer holds what dictation wrote: no cleanup swap.
    private(set) var spanEdited = false

    // Cleanup after you stop: the raw words go in at once, the cleaned ones replace them when ready.

    struct Cleanup: Equatable {
        let raw: String
        let cleaned: String
    }

    /// True while the on-device model is cleaning up the last dictation.
    private(set) var isCleaning = false
    private var cleanupTask: Task<Void, Never>?
    /// The last swap, for the composer's Undo. Nil once it's no longer in the box as written.
    private(set) var lastCleanup: Cleanup?
    /// Give up on a cleanup that takes longer than this; your raw words are already in the box.
    static let cleanupTimeout: Duration = .seconds(15)

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
        endCleanup()
        state = .starting
        // This start, so a cancel (Esc, closing the chat, Send) during the awaits below wins: a start
        // that's no longer current tears down instead of turning the mic on.
        let token = session
        func superseded() -> Bool { state != .starting || session != token }
        guard await Self.microphoneAllowed() else {
            guard !superseded() else { return }
            fail("Microphone access is off for Lasso. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }
        guard !superseded() else { return }
        beginSpan()
        DictationCleaner.prewarm()
        do {
            let live = try await AppleLiveTranscription.make(localeID: await Self.englishLocaleID())
            guard !superseded() else { live.cancel(); return }
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw VoiceInputError("No microphone is available.")
            }
            let activity = SpeechActivity()
            Self.installTap(on: input, format: format, sink: live, activity: activity)
            self.live = live
            self.activity = activity
            let session = self.session
            try await live.start { finalized, volatile in
                Task { @MainActor in
                    VoiceInputController.shared.show(finalized, volatile: volatile, session: session)
                }
            }
            guard !superseded() else {
                input.removeTap(onBus: 0)
                live.cancel()
                if self.live === live { self.live = nil; self.activity = nil }
                return
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

    /// Stop listening. The final text replaces the live draft in the box straight away, then cleanup
    /// (if it's on) runs and swaps in the cleaned text.
    func stop() async {
        guard state == .listening else { return }
        silenceWatch?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let live = self.live
        self.live = nil
        state = .finishing
        let token = session
        do {
            let text = try await Self.finish(live)
            // Cancelled while finishing: the box is back to what it was; nothing more is written.
            guard session == token, state == .finishing else { return }
            show(text, session: session)
            session += 1
            state = .idle
            let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if DictationCleaner.isEnabled, !raw.isEmpty {
                cleanUp(raw, useModel: DictationCleaner.modelAvailable)
            }
        } catch {
            guard session == token else { return }
            session += 1
            fail(error.localizedDescription)
        }
    }

    /// Stop without keeping anything: the message box goes back to what it was.
    func cancel() {
        guard isActive else { return }
        live?.cancel()
        teardown()
        let editor = Composer.current
        if !spanEdited, NSMaxRange(span) <= (editor.text as NSString).length {
            editor.replace(span, with: replaced, caret: nil, undoable: false)
        }
        editor.markVolatile(nil)
        // A new session: a start or finish still in flight sees it isn't current any more.
        session += 1
        state = .idle
    }

    /// Send what's in the box, finishing any dictation first so its last words are included and
    /// nothing the recognizer says afterwards reaches the box. A cleanup still running is dropped:
    /// what you see is what's sent.
    func sendEndingDictation() async {
        switch state {
        case .listening: await stop()
        case .starting: cancel()
        case .finishing: return          // a stop is already finishing; it will fill the box
        case .idle, .failed: break
        }
        if case .failed = state { return }
        endCleanup()
        ChatController.shared.send()
    }

    /// End a live transcription and return its text. Runs in its own task: a caller that has been
    /// cancelled (the silence watcher, which the stop cancels) must not cancel the finish with it.
    static func finish(_ live: AppleLiveTranscription?) async throws -> String {
        guard let live else { return "" }
        return try await Task { try await live.finish() }.value
    }

    // MARK: The span in the box

    /// Mark where this dictation's words will go: the caret, or the selection they'll replace.
    func beginSpan(in editor: ComposerEditing = Composer.current) {
        editor.beginDictation()
        let ns = editor.text as NSString
        let selection = editor.selectedRange
        let at = NSMaxRange(selection) <= ns.length ? selection : NSRange(location: ns.length, length: 0)
        replaced = ns.substring(with: at)
        span = at
        spanEdited = false
        lastCleanup = nil
        lead = at.location > 0 && !Self.isSpace(ns.character(at: at.location - 1)) ? " " : ""
        let after = NSMaxRange(at)
        trail = after < ns.length && !Self.isSpace(ns.character(at: after))
            && !Self.isClosingPunctuation(ns.character(at: after)) ? " " : ""
    }

    /// Write what was heard into the span, but only for the dictation that's still running. The
    /// caret follows the newest word; the recognizer's unconfirmed words are greyed out.
    func show(_ finalized: String, volatile: String = "", session: Int) {
        guard session == self.session else { return }
        let editor = Composer.current
        let heard = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        activity?.note(transcript: heard, at: Date())
        let text = heard.isEmpty ? replaced : lead + heard + trail
        guard NSMaxRange(span) <= (editor.text as NSString).length else { return }
        let caret = span.location + (heard.isEmpty ? text : lead + heard).utf16.count
        editor.replace(span, with: text, caret: caret, undoable: false)
        span.length = text.utf16.count
        let unconfirmed = min(volatile.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count,
                              heard.utf16.count)
        editor.markVolatile(unconfirmed > 0 ? NSRange(location: caret - unconfirmed, length: unconfirmed) : nil)
    }

    /// The person typed in the box. Edits before the span move it; edits inside it mean the cleaned
    /// text must not overwrite theirs.
    func composerEdited(_ range: NSRange, replacementLength: Int) {
        if NSMaxRange(range) <= span.location {
            span.location += replacementLength - range.length
        } else if range.location < NSMaxRange(span) {
            spanEdited = true
        }
    }

    // MARK: Cleanup

    /// Clean `raw` (already in the box) and swap the result in when it's ready.
    func cleanUp(_ raw: String, useModel: Bool) {
        endCleanup()
        isCleaning = useModel
        let task = Task { [weak self] in
            let outcome = await DictationCleaner.clean(raw, useModel: useModel)
            guard let self, !Task.isCancelled else { return }
            self.isCleaning = false
            self.cleanupTask = nil
            Log.voice.info("Dictation cleanup route: \(outcome.route.rawValue, privacy: .public)")
            self.swapIn(outcome.text, for: raw)
        }
        cleanupTask = task
        Task { [weak self] in
            try? await Task.sleep(for: Self.cleanupTimeout)
            guard let self, self.cleanupTask == task else { return }
            Log.voice.notice("Dictation cleanup timed out; keeping the raw text")
            self.endCleanup()
        }
    }

    /// Replace `raw` with `cleaned` in the box, as one undoable step, if the box still holds `raw`
    /// exactly where dictation put it.
    func swapIn(_ cleaned: String, for raw: String) {
        guard cleaned != raw, !cleaned.isEmpty, !spanEdited else { return }
        let editor = Composer.current
        let ns = editor.text as NSString
        guard NSMaxRange(span) <= ns.length, ns.substring(with: span) == lead + raw + trail else { return }
        let rawRange = NSRange(location: span.location + lead.utf16.count, length: raw.utf16.count)
        let delta = cleaned.utf16.count - raw.utf16.count
        let selection = editor.selectedRange
        let caret = selection.location >= NSMaxRange(rawRange) ? selection.location + delta
            : min(selection.location, rawRange.location + cleaned.utf16.count)
        editor.replace(rawRange, with: cleaned, caret: caret, undoable: true)
        span.length += delta
        lastCleanup = Cleanup(raw: raw, cleaned: cleaned)
    }

    /// The last cleanup, while the box still shows it as written (for the composer's Undo).
    var undoableCleanup: Cleanup? {
        guard let cleanup = lastCleanup, !spanEdited, !isActive else { return nil }
        let ns = ChatController.shared.input as NSString
        guard NSMaxRange(span) <= ns.length,
              ns.substring(with: span) == lead + cleanup.cleaned + trail else { return nil }
        return cleanup
    }

    /// Put the raw words back.
    func undoCleanup() {
        guard let cleanup = undoableCleanup else { return }
        let range = NSRange(location: span.location + lead.utf16.count, length: cleanup.cleaned.utf16.count)
        Composer.current.replace(range, with: cleanup.raw, caret: nil, undoable: true)
        span.length += cleanup.raw.utf16.count - cleanup.cleaned.utf16.count
        lastCleanup = nil
    }

    /// Drop a running cleanup and forget the last one.
    private func endCleanup() {
        cleanupTask?.cancel()
        cleanupTask = nil
        isCleaning = false
        lastCleanup = nil
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }

    private static func isClosingPunctuation(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return ".,!?;:)]}\"'".unicodeScalars.contains(scalar)
    }

    private func teardown() {
        session += 1
        silenceWatch?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        live = nil
        activity = nil
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

/// Decides when dictation is over, from loudness and from what's been said. Written from the audio
/// thread and the recognizer, read from the main actor.
///
/// A fixed 2 s pause cut people off mid-thought ("I want to… and"). The pause it waits for now depends
/// on the words so far: short after a finished sentence, long after "and", "so", "the", "um" or a comma,
/// in between otherwise. New words from the recognizer count as speech, so a quiet voice isn't cut off;
/// loudness covers the moment before the recognizer catches up, but noise that brings no words (a fan,
/// music) can only hold dictation open a little past the last word.
final class SpeechActivity: @unchecked Sendable {
    enum Decision: Equatable { case keepListening, stop, nothingHeard }

    /// RMS above this is speech (about -34 dBFS). Room noise and a quiet fan sit well below it.
    static let speechLevel: Float = 0.02
    /// Give up if nothing is said for this long after starting.
    static let noSpeechTimeout: TimeInterval = 8.0
    /// Loud sound with no new words keeps listening at most this long after the last word.
    static let noiseWithoutWords: TimeInterval = 3.0

    /// How long a pause ends dictation, by how the words so far end.
    static let pauseAfterSentence: TimeInterval = 1.3
    static let pauseMidSentence: TimeInterval = 2.2
    static let pauseMidThought: TimeInterval = 3.5

    private let lock = NSLock()
    private var lastLoud: Date?
    private var lastWords: Date?
    private var transcript = ""

    func note(level: Float, at time: Date) {
        guard level >= Self.speechLevel else { return }
        lock.withLock { lastLoud = time }
    }

    /// Everything heard so far. More words mean the person is still talking; the recognizer revising
    /// what it already has (capitals and a full stop when it settles a sentence) doesn't.
    func note(transcript text: String, at time: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if Self.wordCount(text) > Self.wordCount(transcript) { lastWords = time }
            transcript = text
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).count
    }

    func decision(now: Date, startedAt: Date) -> Decision {
        let (loud, words, text) = lock.withLock { (lastLoud, lastWords, transcript) }
        // Before any words, loudness alone: the recognizer takes a moment, and stopping then still
        // returns what it was working on. After words, noise only counts for a little.
        let loudThatCounts = loud.map { loud in words.map { min(loud, $0.addingTimeInterval(Self.noiseWithoutWords)) } ?? loud }
        guard let last = [words, loudThatCounts].compactMap({ $0 }).max() else {
            return now.timeIntervalSince(startedAt) >= Self.noSpeechTimeout ? .nothingHeard : .keepListening
        }
        if words == nil, now.timeIntervalSince(startedAt) >= Self.noSpeechTimeout { return .nothingHeard }
        return now.timeIntervalSince(last) >= Self.pause(after: text) ? .stop : .keepListening
    }

    /// Words a sentence doesn't end on: someone who stops after one is still thinking.
    /// Pronouns and words like "that" or "on" are left out: plenty of sentences end on them ("thank
    /// you", "turn it on"), and those shouldn't wait the long pause.
    static let continuers: Set<String> = [
        "and", "but", "or", "so", "because", "cause", "if", "than", "which", "while", "like",
        "um", "uh", "er", "erm", "hmm", "the", "a", "an", "to", "of", "for", "with", "from", "into",
        "my", "your", "our", "their", "its", "i", "we", "is", "are", "was", "were", "be", "am",
        "can", "could", "should", "would", "will", "just", "and then", "kind of", "sort of",
    ]

    static func pause(after text: String) -> TimeInterval {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return pauseMidSentence }
        if ".?!".contains(last) { return pauseAfterSentence }
        if ",;:-".contains(last) || last == "\u{2026}" { return pauseMidThought }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        guard let word = words.last.map(String.init) else { return pauseMidSentence }
        let pair = words.count >= 2 ? "\(words[words.count - 2]) \(word)" : ""
        return continuers.contains(word) || continuers.contains(pair) ? pauseMidThought : pauseMidSentence
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
