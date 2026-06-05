import SwiftUI

/// Lasso — on-device screen search for Apple Silicon Macs.
///
/// Menu-bar agent app (`LSUIElement`, `.accessory` policy). The hotkey and the menu both trigger
/// `CaptureCoordinator.begin()`. Wiring (registry, intelligence, login item) happens in
/// `AppDelegate.applicationDidFinishLaunching` to keep main-actor isolation clean.
@main
struct LassoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Lasso", systemImage: "lasso") {
            MenuBarController()
        }

        Settings {
            SettingsView(intelligence: .shared)
        }
    }
}
