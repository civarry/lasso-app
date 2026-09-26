import Testing
import Foundation
@testable import Lasso

/// Apple's on-device model supports 23 languages and Filipino isn't one; it writes Filipino anyway,
/// badly ("Pumirma tayo kung mayroon ka…"). A request that needs a language it doesn't support must
/// never be answered by it: not as the chosen model, and not as the fallback's last resort.
@MainActor
@Suite(.serialized)
struct TranslationModelLanguageTests {

    @Test func onDeviceSupportsOnlyItsOwnLanguages() {
        #expect(!OnDeviceProvider.supports(languages: ["fil"]))
        #expect(!OnDeviceProvider.supports(languages: ["en", "fil"]))
        #expect(OnDeviceProvider.supports(languages: ["en", "ja"]))
        #expect(OnDeviceProvider.supports(languages: []))
    }

    /// The fallback's last resort is gated the same way as its context window.
    @Test func fallbackNeverHandsFilipinoToOnDevice() {
        let turns = [ChatTurn(role: .user, text: "Dear Valued Subscriber,")]
        var needs = FallbackNeeds(messages: turns, tools: .none, primaryModel: nil)
        #expect(FallbackPolicy.onDeviceCanHold(needs))
        needs.languages = ["en", "fil"]
        #expect(!FallbackPolicy.onDeviceCanHold(needs))
        needs.languages = ["en", "ja"]
        #expect(FallbackPolicy.onDeviceCanHold(needs))
    }

    /// With Apple's model chosen, a Filipino request is refused before anything is generated.
    @Test func chosenOnDeviceModelRefusesFilipino() async {
        let coordinator = IntelligenceCoordinator.shared
        let saved = coordinator.preferred
        coordinator.preferred = .onDevice
        defer { coordinator.preferred = saved }

        let stream = coordinator.respond(messages: [ChatTurn(role: .user, text: "Thank you.")],
                                         languages: ["en", "fil"])
        var text = ""
        await #expect(throws: IntelligenceError.self) {
            for try await delta in stream { text += delta }
        }
        #expect(text.isEmpty)
    }
}
