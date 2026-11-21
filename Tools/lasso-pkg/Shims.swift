import Foundation

// The few app types the shared package engine names, as the command-line tool sees them: no
// local-only mode (that's a Lasso setting), and search hits as plain values.

enum PrivacyMode {
    static let localOnly = false
}

enum WebSourcesProvider {
    struct Hit {
        let title: String
        let url: URL?
        let source: String
        var snippet: String?
    }
}
