import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A frozen capture of one display plus the geometry needed to place an overlay over it.
struct DisplayShot: Identifiable, @unchecked Sendable {
    let id: CGDirectDisplayID
    /// Native-resolution frozen pixels.
    let image: CGImage
    /// The display's frame in global AppKit point coordinates (for window placement).
    let frame: CGRect
    /// Backing scale factor (pixels per point).
    let scale: CGFloat

    var displayID: CGDirectDisplayID { id }
}

/// One-shot capture of every display via ScreenCaptureKit. This *is* the "freeze" — it runs
/// before any overlay is shown so the overlay just blits an already-decoded image (Spec §6).
enum ScreenCaptureService {
    enum CaptureError: LocalizedError {
        case noDisplays
        case permissionDenied
        var errorDescription: String? {
            switch self {
            case .noDisplays: "No displays available to capture."
            case .permissionDenied: "Screen Recording permission is required."
            }
        }
    }

    static func captureAllDisplays() async throws -> [DisplayShot] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        var shots: [DisplayShot] = []
        for display in content.displays {
            let nsScreen = matchingScreen(for: display.displayID)
            let scale = nsScreen?.backingScaleFactor ?? 2
            let frame = nsScreen?.frame ?? display.frame

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg)
            shots.append(DisplayShot(id: display.displayID, image: image,
                                     frame: frame, scale: scale))
        }
        return shots
    }

    private static func matchingScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
        }
    }
}
