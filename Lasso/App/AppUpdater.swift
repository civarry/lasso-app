import AppKit
import Observation
import Sparkle

/// In-app updates, through Sparkle.
///
/// Lasso reads the update feed (`appcast.xml`, published with each GitHub release; `SUFeedURL` in
/// Info.plist) and installs a new version only if its archive is signed with Lasso's update key
/// (EdDSA; the public half is `SUPublicEDKey`, the private half stays in the maintainer's Keychain).
/// That key, not Apple's code signature, is what an update is trusted by, so updates keep working when
/// the Apple Development certificate changes.
///
/// No web view anywhere: release notes in the feed are plain text (`sparkle:format="plain-text"`),
/// which Sparkle shows in a text view. Local-only mode blocks every check at the source
/// (`updater(_:mayPerform:)`), whatever starts it: the schedule, the menu, or Settings.
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// Mirrors Sparkle's own setting (stored by Sparkle in Lasso's defaults).
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Download and install updates on their own (Sparkle's setting; on by default via
    /// `SUAutomaticallyUpdate`). Installed as soon as Lasso is idle, see `installWhenIdle`.
    var automaticallyInstalls: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Whether "Check for Updates…" can run right now (not already checking, not local-only).
    var canCheck: Bool { (controller?.updater.canCheckForUpdates ?? false) && !PrivacyMode.localOnly }

    /// Called once at launch.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    @ObservationIgnored private var pendingInstall: (() -> Void)?
    @ObservationIgnored private var idleTimer: Timer?

    /// A downloaded update installs, and Lasso relaunches, the first moment nothing is in progress.
    /// Waiting for a quit would mean weeks: a menu bar app rarely quits.
    func installWhenIdle(_ install: @escaping () -> Void) {
        pendingInstall = install
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in AppUpdater.shared.installIfIdle() }
        }
        installIfIdle()
    }

    /// Idle: no capture overlay up, no chat reply (or Agent turn) streaming in any conversation.
    static var isIdle: Bool {
        !CaptureCoordinator.shared.isActive && !ChatController.shared.sessions.contains { $0.isStreaming }
    }

    private func installIfIdle() {
        guard let install = pendingInstall, Self.isIdle else { return }
        pendingInstall = nil
        idleTimer?.invalidate()
        idleTimer = nil
        Log.app.notice("update · installing a downloaded update while idle")
        install()
    }

    func checkForUpdates() {
        guard !PrivacyMode.localOnly else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Sparkle has an update downloaded and would install it at quit; Lasso installs it when idle
    /// instead (returning true means Lasso takes over the timing).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let install = UncheckedInstall(run: immediateInstallHandler)
        Task { @MainActor in AppUpdater.shared.installWhenIdle(install.run) }
        return true
    }

    /// The one gate for every update check: local-only means nothing leaves the Mac.
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if PrivacyMode.localOnly {
            throw NSError(domain: "Lasso.Updates", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Update checks are off in local-only mode.",
            ])
        }
    }
}

/// Sparkle's install block crosses to the main actor once; it's only ever called there.
private struct UncheckedInstall: @unchecked Sendable {
    let run: () -> Void
}
