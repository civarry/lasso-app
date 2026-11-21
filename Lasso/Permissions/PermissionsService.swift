import AppKit
import CoreServices
import CoreGraphics

/// Screen Recording (TCC) gate for ScreenCaptureKit. Checked before each capture (Spec §13).
///
/// macOS keeps one permission per app ID, tied to the signature of the copy that was allowed. When
/// another copy with the same ID asks (an older version signed differently, a build from Xcode), the
/// permission stops matching this one: System Settings still shows Lasso switched on, but Lasso isn't
/// allowed, and asking again does nothing. `reset` clears Lasso's own entry so macOS asks afresh.
@MainActor
@Observable
final class PermissionsService {
    /// The permissions Lasso can be stuck on: both stay "on" in System Settings when stale.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case screenRecording, accessibility
        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .accessibility: "Accessibility"
            }
        }

        /// What Lasso uses it for.
        var use: String {
            switch self {
            case .screenRecording: "To capture what you lasso."
            case .accessibility: "To read and replace highlighted text."
            }
        }

        /// `tccutil`'s name for it.
        var service: String {
            switch self {
            case .screenRecording: "ScreenCapture"
            case .accessibility: "Accessibility"
            }
        }

        var settingsURL: URL {
            let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    /// Non-prompting check: is Screen Recording already granted?
    var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func isAllowed(_ kind: Kind) -> Bool {
        switch kind {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
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
        NSWorkspace.shared.open(Kind.screenRecording.settingsURL)
    }

    enum ResetError: LocalizedError, Equatable {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let detail): "macOS didn't reset it: \(detail)" }
        }
    }

    /// Clears macOS's entry for this app (only this app's, only this permission), then asks again:
    /// macOS shows its prompt and adds Lasso back to the list, switched off, for the user to switch on.
    func reset(_ kind: Kind, bundleID: String = Bundle.main.bundleIdentifier ?? "com.cjcarito.Lasso") async throws {
        try await Self.tccReset(kind.service, bundleID: bundleID)
        switch kind {
        case .screenRecording:
            hasRequestedOnce = true
            CGRequestScreenCaptureAccess()
        case .accessibility:
            // The literal key: the `kAXTrustedCheckOptionPrompt` global isn't concurrency-safe in Swift 6.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// `tccutil reset <service> <bundleID>`. An app may reset its own entries without an admin password.
    nonisolated static func tccReset(_ service: String, bundleID: String) async throws {
        // tccutil finds the app through Launch Services, which may not know a copy run from Xcode or
        // a build folder ("No such bundle identifier"): register this copy first.
        if bundleID == Bundle.main.bundleIdentifier { LSRegisterURL(Bundle.main.bundleURL as CFURL, true) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleID]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        guard status == 0 else {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ResetError.failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
