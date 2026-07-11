import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registry: ActionRegistry?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Defaults for user settings that should start enabled.
        UserDefaults.standard.register(defaults: ["translation.pretranslate": true])

        // Agent app: no Dock icon, no app menu (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)

        // Drop a pre-IPv4 cached "localhost" Ollama URL so we don't re-hit the refused ::1 socket.
        OllamaEndpoint.migrateDetectedLocalhostToIPv4()

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
