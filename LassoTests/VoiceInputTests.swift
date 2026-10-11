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

/// Dictation ends itself: 2 s after you stop talking, or after 8 s if nothing was said.
struct SpeechActivityTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func stopsAfterAPauseFollowingSpeech() {
        let activity = SpeechActivity()
        #expect(activity.decision(now: t0.addingTimeInterval(1), startedAt: t0) == .keepListening)
        activity.note(level: 0.1, at: t0.addingTimeInterval(1.5))
        #expect(activity.decision(now: t0.addingTimeInterval(3.0), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: t0.addingTimeInterval(3.6), startedAt: t0) == .stop)
    }

    @Test func quietRoomNoiseIsNotSpeech() {
        let activity = SpeechActivity()
        activity.note(level: 0.005, at: t0.addingTimeInterval(1))
        #expect(activity.decision(now: t0.addingTimeInterval(7.9), startedAt: t0) == .keepListening)
        #expect(activity.decision(now: t0.addingTimeInterval(8.0), startedAt: t0) == .nothingHeard)
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

        ChatController.shared.input = "typed after sending"
        voice.show("late words from the recognizer", session: voice.session - 1)
        #expect(ChatController.shared.input == "typed after sending")

        voice.show("words from the running dictation", session: voice.session)
        #expect(ChatController.shared.input == "words from the running dictation")
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
        try await live.start { _ in }
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
