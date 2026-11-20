import Testing
import Foundation
import AVFoundation
@testable import Lasso

/// Apple's on-device recognizer end to end, from an audio file macOS speaks for us (no microphone).
struct AppleSpeechFileTests {
    @Test func transcribesSpokenEnglishOnDevice() async throws {
        // Virtual Macs (the CI runner) report on-device speech as unsupported; nothing to test there.
        guard await AppleSpeech.isSupported(localeID: "en_US") else {
            print("skipped: on-device speech recognition is unsupported on this Mac"); return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-voice-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "Please send the invoice before the meeting tomorrow."]
        try say.run(); say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let text = try await AppleSpeech.transcribe(file: file, localeID: "en_US")
        #expect(text.lowercased().contains("invoice"), "heard: \(text)")
        #expect(text.lowercased().contains("meeting"), "heard: \(text)")
    }
}

/// AVAudioEngine calls the microphone tap on its audio thread. A tap block built inside the
/// @MainActor controller inherited main-actor isolation, and Swift's runtime check trapped the first
/// time audio arrived (`_dispatch_assert_queue_fail`, SIGTRAP). This runs the controller's real tap
/// through a real AVAudioEngine that renders off the main thread, with a generated tone in place of
/// the microphone. With the bug, the test process traps.
@MainActor
struct MicrophoneTapTests {
    @Test func tapRunsOnTheAudioThread() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let engine = AVAudioEngine()
        let source = makeToneSource(format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

        let sink = CountingSink()
        // Installed from the main actor, exactly as the controller does.
        VoiceInputController.installTap(on: engine.mainMixerNode, format: engine.mainMixerNode.outputFormat(forBus: 0),
                                        sink: sink)
        try engine.start()
        nonisolated(unsafe) let rendering = engine
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInteractive).async {   // off the main thread, like the audio thread
                let out = AVAudioPCMBuffer(pcmFormat: rendering.manualRenderingFormat, frameCapacity: 4096)!
                for _ in 0..<20 { _ = try? rendering.renderOffline(4096, to: out) }
                done.resume()
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        // 20 × 4096 frames at 48 kHz ≈ 1.7 s → ~27,000 frames at 16 kHz.
        #expect(sink.frames > 20_000, "the tap delivered \(sink.frames) frames")
    }
}

/// Stands in for the recognizer: counts the converted frames it's fed (16 kHz mono, like Apple's).
final class CountingSink: AudioSink, @unchecked Sendable {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var count = 0
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func feed(_ buffer: AVAudioPCMBuffer) { lock.lock(); count += Int(buffer.frameLength); lock.unlock() }
}

/// A 48 kHz tone in place of a microphone. Built outside the main actor for the same reason.
private nonisolated func makeToneSource(_ format: AVAudioFormat) -> AVAudioSourceNode {
    final class Phase: @unchecked Sendable { var value: Float = 0 }
    let phase = Phase()
    return AVAudioSourceNode(format: format) { _, _, frames, list -> OSStatus in
        let samples = UnsafeMutableAudioBufferListPointer(list)[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frames) { samples[i] = sinf(phase.value) * 0.3; phase.value += 0.05 }
        return noErr
    }
}

/// Dictation ends itself once you've finished: the pause it waits for depends on how your words end,
/// new words keep it open however quietly you speak, and noise without words can't hold it open.
struct SpeechActivityTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func pauseDependsOnHowTheWordsEnd() {
        #expect(SpeechActivity.pause(after: "Book a table for two.") == SpeechActivity.pauseAfterSentence)
        #expect(SpeechActivity.pause(after: "What time is it?") == SpeechActivity.pauseAfterSentence)
        #expect(SpeechActivity.pause(after: "I want to go and") == SpeechActivity.pauseMidThought)
        #expect(SpeechActivity.pause(after: "send it to the") == SpeechActivity.pauseMidThought)
        #expect(SpeechActivity.pause(after: "first the report, um") == SpeechActivity.pauseMidThought)
        #expect(SpeechActivity.pause(after: "first the report,") == SpeechActivity.pauseMidThought)
        #expect(SpeechActivity.pause(after: "it was kind of") == SpeechActivity.pauseMidThought)
        #expect(SpeechActivity.pause(after: "thank you") == SpeechActivity.pauseMidSentence)
        #expect(SpeechActivity.pause(after: "turn it on") == SpeechActivity.pauseMidSentence)
        #expect(SpeechActivity.pauseAfterSentence < SpeechActivity.pauseMidSentence)
        #expect(SpeechActivity.pauseMidSentence < SpeechActivity.pauseMidThought)
    }

    @Test func stopsSoonAfterAFinishedSentence() {
        let activity = SpeechActivity()
        activity.note(level: 0.1, at: at(1))
        activity.note(transcript: "Remind me at five.", at: at(1.5))
        #expect(activity.decision(now: at(2.6), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(2.9), startedAt: t0) == .stop)
    }

    @Test func waitsLongerMidThought() {
        let activity = SpeechActivity()
        activity.note(level: 0.1, at: at(1))
        activity.note(transcript: "I need to email Sam and", at: at(1.5))
        // The old fixed 2 s pause stopped here, mid-sentence.
        #expect(activity.decision(now: at(4.0), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(5.1), startedAt: t0) == .stop)
    }

    @Test func newWordsCountAsSpeechEvenWhenQuiet() {
        let activity = SpeechActivity()
        activity.note(level: 0.005, at: at(1))   // below the loudness threshold
        activity.note(transcript: "hello", at: at(1.2))
        activity.note(transcript: "hello there", at: at(3.0))
        #expect(activity.decision(now: at(4.5), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(5.3), startedAt: t0) == .stop)
    }

    @Test func revisingTheSameWordsIsNotMoreSpeech() {
        let activity = SpeechActivity()
        activity.note(transcript: "remind me at five", at: at(1))
        // The recognizer settles the sentence a moment into the pause.
        activity.note(transcript: "Remind me at five.", at: at(2))
        #expect(activity.decision(now: at(2.4), startedAt: t0) == .stop)
    }

    @Test func noiseWithoutWordsCantHoldItOpen() {
        let activity = SpeechActivity()
        activity.note(transcript: "Remind me at five.", at: at(1))
        for tick in stride(from: 1.0, through: 20, by: 0.1) { activity.note(level: 0.1, at: at(tick)) }
        let limit = 1 + SpeechActivity.noiseWithoutWords + SpeechActivity.pauseAfterSentence
        #expect(activity.decision(now: at(limit - 0.1), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(limit + 0.1), startedAt: t0) == .stop)
    }

    @Test func noiseAloneEndsAsNothingHeard() {
        let activity = SpeechActivity()
        for tick in stride(from: 0.0, through: 10, by: 0.1) { activity.note(level: 0.1, at: at(tick)) }
        #expect(activity.decision(now: at(7.9), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(8.0), startedAt: t0) == .nothingHeard)
    }

    @Test func loudnessBeforeTheFirstWordsCounts() {
        // The recognizer lags: speech was heard, then a pause, before any words arrived.
        let activity = SpeechActivity()
        activity.note(level: 0.1, at: at(1.5))
        #expect(activity.decision(now: at(3.0), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(3.8), startedAt: t0) == .stop)
    }

    @Test func quietRoomNoiseIsNotSpeech() {
        let activity = SpeechActivity()
        activity.note(level: 0.005, at: at(1))
        #expect(activity.decision(now: at(7.9), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: at(8.0), startedAt: t0) == .nothingHeard)
    }

    @Test func levelIsTheRMSOfTheBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        for i in 0..<100 { buffer.floatChannelData![0][i] = i.isMultiple(of: 2) ? 0.5 : -0.5 }
        #expect(abs(SpeechActivity.level(of: buffer) - 0.5) < 0.0001)
    }
}

/// Sending while dictating left the recognizer running, and its next update put the sent text back in
/// the box. Updates from a dictation that has ended must be ignored.
@MainActor
@Suite(.serialized)
struct VoiceSessionTests {
    @Test func anUpdateFromAnEndedDictationDoesNotTouchTheBox() {
        let voice = VoiceInputController.shared
        let saved = ChatController.shared.input
        defer { ChatController.shared.input = saved }

        let savedView = Composer.textView
        Composer.textView = nil
        defer { Composer.textView = savedView }

        ChatController.shared.input = "typed after sending"
        voice.beginSpan()
        voice.show("late words from the recognizer", session: voice.session - 1)
        #expect(ChatController.shared.input == "typed after sending")

        voice.show("words from the running dictation", session: voice.session)
        #expect(ChatController.shared.input == "typed after sending words from the running dictation")
    }
}

/// The live path minus the microphone: macOS speaks a sentence, it's streamed into Apple's live
/// recognizer in mic-sized chunks, and dictation is finished from a *cancelled* task, which is where
/// the automatic stop used to run it (its watcher cancelled itself, then stopped). The text must
/// survive.
struct LiveDictationTests {
    @Test func finishingFromACancelledTaskKeepsTheText() async throws {
        guard await AppleSpeech.isSupported(localeID: "en_US") else {
            print("skipped: on-device speech recognition is unsupported on this Mac"); return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-live-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "Please send the invoice before the meeting tomorrow."]
        try say.run(); say.waitUntilExit()

        let live = try await AppleLiveTranscription.make(localeID: "en_US")
        try await live.start { _, _ in }
        let audio = try AVAudioFile(forReading: file)
        let converter = BufferConverter(from: audio.processingFormat, to: live.format)
        while audio.framePosition < audio.length {
            let chunk = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)!
            try audio.read(into: chunk)
            if let converted = converter?.convert(chunk) { live.feed(converted) }
        }

        let finishing = Task { () -> Result<String, Error> in
            withUnsafeCurrentTask { $0?.cancel() }           // like the watcher, already cancelled
            do { return .success(try await VoiceInputController.finish(live)) } catch { return .failure(error) }
        }
        let text = try await finishing.value.get()
        #expect(text.lowercased().contains("invoice"), "heard: \(text)")
    }
}
