import SwiftUI

/// Shared visual constants for the floating overlay UI.
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let pillRadius: CGFloat = 9
    static let spacing: CGFloat = 8

    static let panelMaterial: Material = .ultraThinMaterial
}

/// A frosted container used for the ActionBar and ResultPane.
struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(10)
            .background(Theme.panelMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}
