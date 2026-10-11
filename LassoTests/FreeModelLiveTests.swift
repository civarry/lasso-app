import Testing
import Foundation
import CoreGraphics
@testable import Lasso

/// Real-provider checks for the free-model fallback, against the connections configured on this Mac.
/// Opt-in, because they touch the network:
///
///     TEST_RUNNER_LASSO_LIVE=1 xcodebuild test -scheme Lasso -only-testing:LassoTests/FreeModelLiveTests
///
/// Cost-safe by construction: model-list calls are free on every provider, and the only chat requests
/// go to models OpenRouter prices at zero. Nothing is sent to Groq or Gemini chat, since this test can't
/// know whether those keys are on a free plan.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LASSO_LIVE"] == "1"))
@MainActor
struct FreeModelLiveTests {

    /// A request that fails for real: the host doesn't resolve, so URLSession reports it the way an
    /// outage does.
    private let unreachable = OpenAICompatibleProvider(baseURL: URL(string: "https://lasso-live-test.invalid/v1")!,
                                                       apiKey: "x", model: "openai/gpt-oss-20b", displayName: "Primary")

    /// The configured OpenRouter connection, opted into the fallback for this test only (the user's own
    /// setting is never written).
    private func openRouterConnection() throws -> RegisteredKey {
        var entry = try #require(KeysRegistry.load().entries.first { FreeTierProvider.identify($0) == .openRouter },
                                 "configure an OpenRouter connection to run the live tests")
        entry.useForFallback = true
        return entry
    }

    /// Discover the OpenRouter connection's models for real and return a registry holding just that.
    private func liveOpenRouterRegistry() async throws -> (KeysRegistry, RegisteredKey) {
        var entry = try openRouterConnection()
        let models = try #require(await KeysRegistry.discoverModels(for: entry, apiKey: Keychain.get(entry.keychainAccount) ?? ""))
        entry.models = models
        return (KeysRegistry(entries: [entry]), entry)
    }

    private func driver(registry: @escaping () -> KeysRegistry, health: ModelHealth = ModelHealth(),
                        refreshInBackground: @escaping () -> Void = {},
                        raceAfter: TimeInterval? = nil,
                        served: @escaping (String) -> Void = { _ in }) -> FallbackDriver {
        FallbackDriver(
            health: health,
            poolAllowed: { FallbackPolicy.poolAllowed(enabled: true, localOnly: false, primaryIsLocal: $0.isLocal) },
            candidates: { needs, tried in
                FreeModelPool.candidates(in: registry(), needs: needs, excluding: tried, isBenched: { health.isBenched($0) })
            },
            refreshInBackground: refreshInBackground,
            makeProvider: { candidate in
                served(candidate.ref.model)
                return IntelligenceCoordinator.provider(for: candidate)
            },
            lastResort: { _, _ in nil },
            raceAfter: { raceAfter })
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await delta in stream { text += delta }
        return text
    }

    // MARK: Detection against every configured connection

    @Test func detectionMatchesWhatEachConfiguredProviderServes() async {
        for entry in KeysRegistry.load().entries {
            guard let models = await KeysRegistry.discoverModels(for: entry, apiKey: Keychain.get(entry.keychainAccount) ?? "") else {
                Issue.record("\(entry.name): model list failed")
                continue
            }
            var probe = entry
            probe.models = models
            probe.freeTier = true         // what the pool would hold if the user turned the switches on
            probe.useForFallback = true
            let free = FreeModelPool.freeModels(in: KeysRegistry(entries: [probe]))
            let offers = Dictionary(grouping: models, by: { $0.freeOffer.map(\.rawValue) ?? "unknown" }).mapValues(\.count)
            print("LIVE detection · \(entry.name) [\(FreeTierProvider.identify(entry)?.displayName ?? "no rule")]: "
                  + "\(models.count) models, offers \(offers), chat-eligible free \(free.count): "
                  + free.prefix(12).map { "\($0.ref.model)(\($0.size.map { "\($0)" } ?? "?"))" }.joined(separator: ", "))
            switch FreeTierProvider.identify(entry) {
            case .openRouter?: #expect(models.contains { $0.freeOffer == .always })
            case .groq?, .google?: #expect(!free.isEmpty, "\(entry.name): the provider rule matched none of the live model ids")
            case nil: #expect(free.isEmpty)
            }
        }
    }

    /// How a missing model really surfaces, so the classification isn't built on an assumption.
    @Test func howOpenRouterReportsAModelThatDoesNotExist() async throws {
        let entry = try openRouterConnection()
        let provider = OpenAICompatibleProvider(baseURL: URL(string: entry.baseURL)!, apiKey: Keychain.get(entry.keychainAccount) ?? "",
                                                model: "lasso-live-test/does-not-exist:free", displayName: "OpenRouter")
        do {
            _ = try await collect(provider.respond(prompt: "hi", context: nil))
            Issue.record("a nonexistent model answered")
        } catch {
            print("LIVE missing model · \(error.localizedDescription) → \(ModelFailure.classify(error))")
        }
    }

    // MARK: Scenario A: a real failure falls back to a detected free model

    @Test func scenarioA_realFailureIsAnsweredByADetectedFreeModel() async throws {
        let (registry, _) = try await liveOpenRouterRegistry()
        var served: [String] = []
        var notices: [FallbackNotice] = []
        let text = try await collect(driver(registry: { registry }, served: { served.append($0) }).stream(
            primary: unreachable, primaryRef: nil,
            needs: FallbackNeeds(prompt: "Reply with exactly: pong", context: nil, primaryModel: "openai/gpt-oss-20b"),
            label: "live-A", onServe: { _ in }, onFallback: { notices.append($0) },
            open: { $0.respond(prompt: "Reply with exactly: pong", context: nil) }))
        print("LIVE A · tried \(served) → \(text.prefix(200)) · notice: \(notices.map(\.text))")
        #expect(notices.count == 1 && notices[0].answeredBy.hasPrefix("OpenRouter"))
        #expect(!text.contains("Answered by"), "the notice never enters the reply")
        #expect(text.lowercased().contains("pong"))
    }

    // MARK: Scenario B: the first free model fails, another is attempted

    @Test func scenarioB_aFailingFreeModelMovesToTheNextCandidate() async throws {
        let (live, entry) = try await liveOpenRouterRegistry()
        var registry = live
        // A free-priced model id that doesn't exist, ranked first by its size, fails for real.
        var ghost = RegistryModel(name: "lasso-live-test/ghost-999b:free")
        ghost.freeOffer = .always
        ghost.contextTokens = 1_000_000
        registry.entries[0].models.insert(ghost, at: 0)
        var served: [String] = []
        let text = try await collect(driver(registry: { registry }, served: { served.append($0) }).stream(
            primary: unreachable, primaryRef: nil,
            needs: FallbackNeeds(prompt: "Reply with exactly: pong", context: nil, primaryModel: nil),
            label: "live-B", onServe: { _ in }, open: { $0.respond(prompt: "Reply with exactly: pong", context: nil) }))
        print("LIVE B · tried \(served) on \(entry.name) → \(text.prefix(200))")
        #expect(served.first == ghost.name)
        #expect(served.count >= 2)
        #expect(!text.contains(ghost.name) && text.lowercased().contains("pong"))
    }

    // MARK: Scenario C: an exhausted pool refreshes in the background, and the next request uses it

    /// The request that finds the pool empty doesn't wait for the refresh (it fails over, here to
    /// nothing, so the selected model's error surfaces). The refresh it schedules discovers the free
    /// models for real, and the next request is answered by one of them.
    @Test func scenarioC_anEmptyPoolRefreshesForTheNextRequest() async throws {
        let store = ScratchDefaults()
        var entry = try openRouterConnection()
        entry.models = []                 // nothing cached: the pool starts exhausted
        entry.modelsCheckedAt = nil
        KeysRegistry(entries: [entry]).save(to: store.defaults)
        let refresher = FreeModelRefresher(store: store.defaults)
        var scheduled: [Task<Void, Never>] = []
        var served: [String] = []
        let live = driver(registry: { KeysRegistry.load(from: store.defaults) },
                          refreshInBackground: { scheduled.append(Task { await refresher.refreshIfDue() }) },
                          served: { served.append($0) })
        let request = { live.stream(
            primary: self.unreachable, primaryRef: nil,
            needs: FallbackNeeds(prompt: "Reply with exactly: pong", context: nil, primaryModel: nil),
            label: "live-C", onServe: { _ in }, open: { $0.respond(prompt: "Reply with exactly: pong", context: nil) }) }

        await #expect(throws: (any Error).self, "nothing to fall back to yet") { _ = try await self.collect(request()) }
        #expect(served.isEmpty)
        #expect(scheduled.count == 1, "one background refresh for the request")
        for task in scheduled { await task.value }

        let refreshed = KeysRegistry.load(from: store.defaults).entries[0]
        let free = FreeModelPool.freeModels(in: KeysRegistry.load(from: store.defaults))
        print("LIVE C · refreshed \(refreshed.models.count) models, \(free.count) free")
        #expect(refreshed.modelsCheckedAt != nil)
        #expect(!free.isEmpty)

        let text = try await collect(request())
        print("LIVE C · next request tried \(served) → \(text.prefix(160))")
        #expect(!served.isEmpty)
        #expect(text.lowercased().contains("pong"))
    }

    // MARK: Scenario D: a non-retryable error doesn't cycle through free models

    @Test func scenarioD_invalidCredentialsSurfaceWithoutFallback() async throws {
        let (registry, entry) = try await liveOpenRouterRegistry()
        let badKey = OpenAICompatibleProvider(baseURL: URL(string: entry.baseURL)!, apiKey: "sk-or-v1-invalid-lasso-live-test",
                                              model: "openai/gpt-oss-20b:free", displayName: "OpenRouter")
        var served: [String] = []
        do {
            _ = try await collect(driver(registry: { registry }, served: { served.append($0) }).stream(
                primary: badKey, primaryRef: nil, needs: FallbackNeeds(prompt: "hi", context: nil, primaryModel: nil),
                label: "live-D", onServe: { _ in }, open: { $0.respond(prompt: "hi", context: nil) }))
            Issue.record("an invalid key answered")
        } catch {
            print("LIVE D · \(error.localizedDescription) → \(ModelFailure.classify(error)), tried \(served)")
            #expect(ModelFailure.classify(error) == .unauthorized)
        }
        #expect(served.isEmpty)
    }

    // MARK: Scenario E: an image request only reaches image-capable models, and they read it

    @Test func scenarioE_imageRequestsGoOnlyToModelsThatReadImages() async throws {
        let (registry, _) = try await liveOpenRouterRegistry()
        let red = try #require(Self.solidImage(red: 1, green: 0, blue: 0))
        let base64 = try #require(ImageEncoder.jpegBase64(red))
        let messages = [ChatTurn(role: .user, text: "What colour is this image? Answer with one word.", imageBase64s: [base64])]
        let needs = FallbackNeeds(messages: messages, tools: .none, primaryModel: nil)

        let all = FreeModelPool.freeModels(in: registry)
        let eligible = FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { _ in false })
        print("LIVE E · \(eligible.count) of \(all.count) free models accept images: \(eligible.map(\.ref.model))")
        #expect(!eligible.isEmpty)
        #expect(eligible.allSatisfy { $0.model.acceptsImages == true })
        #expect(eligible.count < all.count, "some live free models are text-only and must be left out")

        var served: [String] = []
        let text = try await collect(driver(registry: { registry }, served: { served.append($0) }).stream(
            primary: unreachable, primaryRef: nil, needs: needs, label: "live-E",
            onServe: { _ in }, open: { $0.respond(messages: messages) }))
        print("LIVE E · tried \(served) → \(text.prefix(200))")
        #expect(served.allSatisfy { name in eligible.contains { $0.ref.model == name } })
        #expect(text.lowercased().contains("red"))
    }

    // MARK: Scenario F: a large conversation never reaches a small-window model

    @Test func scenarioF_largeContextExcludesSmallWindows() async throws {
        let (registry, _) = try await liveOpenRouterRegistry()
        let needs = FallbackNeeds(prompt: String(repeating: "word ", count: 240_000), context: nil, primaryModel: nil)
        let all = FreeModelPool.freeModels(in: registry)
        let eligible = FreeModelPool.candidates(in: registry, needs: needs, excluding: [], isBenched: { _ in false })
        print("LIVE F · ~\(needs.estimatedTokens) tokens: \(eligible.count) of \(all.count) free models fit: "
              + eligible.map { "\($0.ref.model)(\($0.contextWindow ?? 0))" }.joined(separator: ", "))
        #expect(eligible.allSatisfy { ($0.contextWindow ?? 0) >= needs.estimatedTokens + ChatContextBuilder.Budget.outputReserveTokens })
        #expect(eligible.count < all.count)
    }

    // MARK: Scenario G: a model that hangs is raced, not waited out

    /// The selected model points at an address that never answers (a non-routable IP), so it hangs the way
    /// a stuck provider does: no error for a full minute. With a 3 s race, a real free model answers
    /// first and the hung request is cancelled.
    @Test func scenarioG_aHungModelIsRacedAndARealFreeModelAnswers() async throws {
        let (registry, _) = try await liveOpenRouterRegistry()
        let hung = OpenAICompatibleProvider(baseURL: URL(string: "http://10.255.255.1/v1")!, apiKey: "x",
                                            model: "openai/gpt-oss-20b", displayName: "Primary")
        var served: [String] = []
        var notices: [FallbackNotice] = []
        let started = Date()
        let text = try await collect(driver(registry: { registry }, raceAfter: 3, served: { served.append($0) }).stream(
            primary: hung, primaryRef: nil,
            needs: FallbackNeeds(prompt: "Reply with exactly: pong", context: nil, primaryModel: "openai/gpt-oss-20b"),
            label: "live-G", onServe: { _ in }, onFallback: { notices.append($0) },
            open: { $0.respond(prompt: "Reply with exactly: pong", context: nil) }))
        let elapsed = Date().timeIntervalSince(started)
        print("LIVE G · raced \(served) → \(text.prefix(80)) in \(Int(elapsed)) s · \(notices.map(\.text))")
        #expect(text.lowercased().contains("pong"))
        #expect(notices.first?.slowAfter == 3)
        #expect(elapsed < 45, "answered by the racer, well before the hung request's 60 s timeout")
    }

    private static func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()
    }
}
