import AppKit
import CoreGraphics

/// Screen Recording (TCC) gate for ScreenCaptureKit. Checked before each capture (Spec §13).
@MainActor
@Observable
final class PermissionsService {
    /// Non-prompting check: is Screen Recording already granted?
    var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// True once we've asked the system for access at least once this launch.
    private(set) var hasRequestedOnce = false

    /// Trigger the system prompt (only effective the first time; afterwards it's a no-op and the
    /// user must grant it in System Settings).
    @discardableResult
    func requestScreenRecording() -> Bool {
        hasRequestedOnce = true
        return CGRequestScreenCaptureAccess()
    }

    /// Deep-link to the Screen Recording pane so the user can flip the toggle.
    func openScreenRecordingSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
