import SwiftUI

/// Shared visual constants for the floating overlay UI.
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let pillRadius: CGFloat = 9
    static let spacing: CGFloat = 8

    static let panelMaterial: Material = .ultraThinMaterial
}

/// Grip used to drag the floating bar/result panel around the screen. Writes a live offset to the
/// coordinator so the action bar, translate bar, and result panels all move together.
struct DragHandle: View {
    @Bindable var coordinator: CaptureCoordinator
    @State private var base: CGSize?

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            // `.global` so translation is measured in screen space, not relative to this handle
            // (which moves with the panel) — avoids the feedback loop that caused lag/ghosting.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = base ?? coordinator.panelDragOffset
                        if base == nil { base = start }
                        coordinator.panelDragOffset = CGSize(
                            width: start.width + value.translation.width,
                            height: start.height + value.translation.height)
                    }
                    .onEnded { _ in base = nil }
            )
            .help("Drag to move")
    }
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
