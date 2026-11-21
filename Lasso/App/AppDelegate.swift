import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registry: ActionRegistry?

    /// Lasso's own Hermes (`HermesRuntime`) goes with it: nothing is left running after quit.
    func applicationWillTerminate(_ notification: Notification) {
        HermesRuntime.shared.stopForQuit()
    }

    /// `lasso://install?id=<id>` opens Browse at that package; nothing installs without the user.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { PackageLinks.handle(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads a setting. Not in the test host, which must not pick up this Mac's settings.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { DevSettingsImport.run() }
        HermesRuntime.shared.cleanUpAfterCrash()
        AppUpdater.shared.start()
        // Defaults for user settings that should start enabled.
        UserDefaults.standard.register(defaults: ["translation.pretranslate": true])

        // Agent app: no Dock icon, no app menu (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)

        // Drop a pre-IPv4 cached "localhost" Ollama URL so we don't re-hit the refused ::1 socket.
        OllamaEndpoint.migrateDetectedLocalhostToIPv4()

        // Tavily and SerpApi became packages: move a saved key over, once. Not in the test host,
        // which shares this Mac's settings and Keychain.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { PackageMigration.run() }
        PackageHotkeys.shared.start()

        let registry = ActionRegistry.makeDefault(intelligence: .shared)
        self.registry = registry
        CaptureCoordinator.shared.configure(registry: registry, intelligence: .shared)
        TriggerService.shared.setUp()

        // Optionally start Ollama, then resolve the server (custom URL / localhost / 127.0.0.1) so the
        // first capture uses a server that actually answers, instead of probing on the hot path.
        Task {
            // Only touch Ollama when the config actually uses it — keeps cloud-only setups quiet.
            if IntelligenceCoordinator.shared.usesOllama {
                if UserDefaults.standard.bool(forKey: "ollama.autoStart") { await OllamaLauncher.start() }
                await OllamaEndpoint.autodetect()
            }
            await IntelligenceCoordinator.shared.refreshVisionAvailability()
            IntelligenceCoordinator.shared.refreshFreeModelsIfStale()
        }

        Log.app.notice("Lasso launched. Capture hotkey active.")
    }
}

/// Launch-at-login via the modern Service Management API (Spec §5).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
