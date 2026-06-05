import Foundation

/// Note on the Translation framework
/// ----------------------------------
/// `TranslationSession` instances are vended by the system through the SwiftUI
/// `.translationTask(_:action:)` modifier — there is no public initializer for programmatic use.
/// Because of that, the actual on-device translation work lives in `TranslationResultView`
/// (UI layer), which owns a `TranslationSession.Configuration` and receives a live session.
///
/// This file documents that decision and is the home for any future non-UI translation helpers
/// (e.g. language availability checks via `LanguageAvailability`).
enum TranslateEngine {
    /// Convenience: is on-device translation between these locales installed/possible?
    /// Implemented in M4 alongside the inline-overlay translate mode.
    static func availabilityNote() -> String {
        "Translation runs on-device via the Translation framework (TranslationResultView)."
    }
}
