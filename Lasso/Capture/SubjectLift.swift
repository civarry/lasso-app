import CoreGraphics
import Vision

/// Tap-an-object → auto-crop the foreground subject (Spec §6, M5).
///
/// Stub: returns the foreground instance mask's bounding box so a single click can crop to a
/// subject. The full interactive flow (per-instance selection at a tapped point) lands in M5.
enum SubjectLift {
    /// Returns the bounding box (normalized, Vision coords) of the most prominent subject, if any.
    static func primarySubjectBox(in image: CGImage) async throws -> CGRect? {
        let request = GenerateForegroundInstanceMaskRequest()
        guard let observation = try await request.perform(on: image) else { return nil }
        // The observation exposes instances + a mask; bounding-box extraction per instance is
        // wired up in M5. For now, signal "a subject exists" so the action can be offered.
        _ = observation
        return nil
    }
}
